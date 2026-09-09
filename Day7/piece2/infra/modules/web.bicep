// Day 24 -- the Angular front end as its own container app.
//
// WHY A SECOND CONTAINER APP RATHER THAN THE API SERVING THE BUNDLE.
//
// On the previous subscription the front end was an Azure Static Web App and the
// API a container app: two resources, two deployments. That separation is worth
// keeping -- a front-end change should not rebuild and redeploy the API, and a
// broken bundle should not be able to take the API down with it.
//
// Static Web Apps cannot be recreated here: Microsoft.Web/staticSites is offered
// in only a handful of regions worldwide and none of them are permitted by this
// subscription's allowed-locations policy. So nginx in a container app takes its
// place, including the reverse proxy that made SWA's linked backend work -- see
// Day13/quotes-web/nginx/default.conf.template.
//
// An intermediate attempt folded the bundle into the API image instead. It cost
// an afternoon to a failure that cannot happen here: StaticFileMiddleware
// declines to serve a file once routing has selected an endpoint, and a
// catch-all SPA fallback selects one for every request, so every asset came back
// as index.html with Content-Type: text/html. nginx has no endpoint concept to
// collide with.

targetScope = 'resourceGroup'

@description('Name of the container app. Must be unique within the Container Apps ENVIRONMENT, not just the resource group.')
param containerAppName string

@description('Location for the container app.')
param location string

@description('Tags applied to the container app.')
param tags object

@description('Resource ID of the Container Apps Environment to run in.')
param containerAppsEnvironmentId string

@description('Resource ID of the user-assigned managed identity used to pull from the registry. The front end needs no Azure data-plane access of its own; this exists so the pull is credential-free, like the API\'s.')
param userAssignedIdentityResourceId string

@description('Login server of the container registry.')
param containerRegistryLoginServer string

@description('Fully qualified image reference. Never empty: main.bicep resolves a supplied image, else the one already running, else a placeholder, exactly as it does for the API.')
@minLength(1)
param imageName string

@description('Base URL of the API this front end proxies /api and /health to. nginx substitutes it into its config at container start, so one image serves any environment.')
@minLength(1)
param apiBaseUrl string

@description('Name of the container inside the app.')
param containerName string = 'quotes-web'

@description('Port nginx listens on. 8080 rather than nginx\'s default 80, so both apps in this template share one contract.')
param targetPort int = 8080

@description('Minimum replicas. 0 enables scale-to-zero. A static-file server starts in well under a second, so a cold start here costs far less than it does on the API.')
@minValue(0)
@maxValue(30)
param minReplicas int

@description('Maximum replicas.')
@minValue(1)
@maxValue(30)
param maxReplicas int

@description('vCPU per replica. nginx serving a 280 kB bundle needs a fraction of what the API needs; 0.25/0.5Gi is the smallest supported pairing.')
param cpu string = '0.25'

@description('Memory per replica. Must pair with cpu per the Container Apps table.')
param memory string = '0.5Gi'

@description('Concurrent requests per replica before the scale rule adds one. Higher than the API\'s: serving a cached static file is not comparable work to a database round trip.')
@minValue(1)
param concurrentRequests int = 100

resource containerApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: containerAppName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentityResourceId}': {}
    }
  }
  properties: {
    managedEnvironmentId: containerAppsEnvironmentId
    configuration: {
      ingress: {
        external: true
        targetPort: targetPort
        transport: 'auto'
      }
      // No secrets. The front end holds none: the API base URL is not one, and
      // the JWT signing key belongs to whoever ISSUES tokens, which is the API.
      // A front end that needed a secret would be a front end doing something
      // it should not.
      registries: [
        {
          server: containerRegistryLoginServer
          identity: userAssignedIdentityResourceId
        }
      ]
    }
    template: {
      containers: [
        {
          name: containerName
          image: imageName
          resources: {
            cpu: json(cpu)
            memory: memory
          }
          env: [
            {
              name: 'API_BASE_URL'
              value: apiBaseUrl
            }
          ]
          probes: [
            // Probes hit '/' rather than a health endpoint, because nginx has
            // none and adding one would mean inventing a route that only the
            // probe uses. A 200 from '/' means the process is up AND index.html
            // is present -- an empty image would fail this, which is the failure
            // most worth catching here.
            //
            // Deliberately NOT proxied through to the API's /health: that would
            // make the front end report unhealthy whenever the API was cold or
            // down, and Container Apps would then restart a perfectly good
            // nginx. Keeping the front end's health about the front end is the
            // point of separating them.
            {
              type: 'Liveness'
              httpGet: {
                path: '/'
                port: targetPort
              }
              initialDelaySeconds: 3
              periodSeconds: 15
            }
            {
              type: 'Readiness'
              httpGet: {
                path: '/'
                port: targetPort
              }
              initialDelaySeconds: 2
              periodSeconds: 10
            }
          ]
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
        rules: [
          {
            name: 'http-concurrency-rule'
            http: {
              metadata: {
                concurrentRequests: '${concurrentRequests}'
              }
            }
          }
        ]
      }
    }
  }
}

output containerAppName string = containerApp.name
output containerAppUri string = 'https://${containerApp.properties.configuration.ingress.fqdn}'
