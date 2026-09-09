// The API — QuotesApi, as an Azure Container App.
//
// WHAT IS PARAMETERIZED AND WHY:
// Everything that differs between a training environment and a production one:
// replica floor and ceiling, CPU and memory, the concurrency the scale rule
// triggers on. The replica floor is the one that matters most — minReplicas: 0
// means scale to zero, which is a cost decision in dev and a cold-start bug in
// prod.
//
// The environment-variable array is a PARAMETER, composed by main.bicep. That
// keeps this module reusable and, more usefully, keeps the whole wiring of the
// application — which connection string, which namespace, which App Insights —
// visible in one place in main.bicep instead of buried three files deep.
//
// The JWT secret is the exception: it arrives as a @secure() string and is
// turned into a Container Apps secret + secretRef here. It cannot travel in the
// `env` array, because that array is a plain (non-secure) parameter and would
// print the value in deployment history.

targetScope = 'resourceGroup'

@description('Name of the container app. Must be unique within the Container Apps ENVIRONMENT, not just the resource group.')
param containerAppName string

@description('Location for the container app.')
param location string

@description('Tags applied to the container app. main.bicep adds azd-service-name.')
param tags object

@description('Resource ID of the Container Apps Environment to run in.')
param containerAppsEnvironmentId string

@description('Resource ID of the user-assigned managed identity the app runs as.')
param userAssignedIdentityResourceId string

@description('Login server of the container registry, e.g. crabc123.azurecr.io.')
param containerRegistryLoginServer string

@description('Fully qualified image reference. REQUIRED and never empty: main.bicep resolves it — supplied image, else the image the app is already running, else a placeholder. This module deliberately has no fallback of its own, because a fallback here could not see the running app and would overwrite it. See modules/fetch-container-image.bicep.')
@minLength(1)
param imageName string

@description('Name of the container inside the app.')
param containerName string = 'quotes-api'

@description('Port the app listens on. QuotesApi listens on 8080 in its container.')
param targetPort int = 8080

@description('Minimum replicas. 0 enables scale-to-zero — a cost win in dev, a cold-start bug in prod.')
@minValue(0)
@maxValue(30)
param minReplicas int

@description('Maximum replicas.')
@minValue(1)
@maxValue(30)
param maxReplicas int

@description('vCPU per replica, as a string so it can be passed through json(). Must pair with memory per the Container Apps CPU/memory table: 0.5/1Gi, 1.0/2Gi, 2.0/4Gi.')
param cpu string = '0.5'

@description('Memory per replica, e.g. 1Gi. See the pairing note on cpu.')
param memory string = '1Gi'

@description('Concurrent requests per replica before the HTTP scale rule adds one.')
@minValue(1)
param concurrentRequests int = 50

@description('Non-secret environment variables, composed by main.bicep. Each entry is { name, value }.')
param env array = []

// Day 25 replaced a @secure() jwtSecret parameter with this one. The old
// parameter meant the signing key travelled from the operator's environment,
// through a parameter file, through the ARM deployment API, into this
// resource — four places holding a value that only ever needed to be in one.
// Now the template carries an ADDRESS and the value stays in the vault.
@description('Full URI of the JWT signing key secret, e.g. https://kv-x.vault.azure.net/secrets/jwt-secret. An address, not a value: reaching it still needs a token this template never issues. Empty falls back to no secret at all, which the app refuses to start without.')
param jwtSecretUri string

var jwtSecretName = 'jwt-secret'

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
      // A KEY VAULT REFERENCE, NOT A VALUE.
      //
      // `identity` names which of the app's identities fetches the secret, and
      // it is required: without it the platform has nothing to authenticate
      // with and the reference cannot resolve. That identity needs Key Vault
      // Secrets User on the vault, which modules/keyvault.bicep grants.
      //
      // TWO THINGS ABOUT HOW THIS RESOLVES, both of which look like bugs the
      // first time they happen:
      //
      //   * It resolves when a REVISION IS CREATED, not per request. Rotating
      //     the secret in the vault therefore does not reach a running app —
      //     the revision keeps what it read at start-up. Rotation is a
      //     deployment, or at minimum a revision restart.
      //   * If it cannot resolve — secret missing, role assignment not yet
      //     propagated — the revision FAILS TO PROVISION. It does not start
      //     degraded and it does not fall back. Expect the first deployment
      //     after the grant to need a retry: RBAC takes roughly 30 seconds to
      //     take effect, and Bicep's dependency ordering guarantees the
      //     assignment is CREATED first, not that it is EFFECTIVE first.
      secrets: [
        {
          name: jwtSecretName
          keyVaultUrl: jwtSecretUri
          identity: userAssignedIdentityResourceId
        }
      ]
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
          env: concat(env, [
            {
              name: 'Jwt__Secret'
              secretRef: jwtSecretName
            }
          ])
          // The health-probe split from Day 5: /health/live answers as soon as
          // the process is up, /health/ready only once dependencies are
          // reachable. Pointing both at /health would make a database outage
          // look like a crash loop.
          probes: [
            {
              type: 'Liveness'
              httpGet: {
                path: '/health/live'
                port: targetPort
              }
              initialDelaySeconds: 5
              periodSeconds: 10
            }
            {
              type: 'Readiness'
              httpGet: {
                path: '/health/ready'
                port: targetPort
              }
              initialDelaySeconds: 5
              periodSeconds: 10
            }
          ]
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
        rules: [
          // `http:`, NOT `custom:` with type 'http'.
          //
          // Both are accepted, and they are not the same thing on the way back
          // out. Container Apps normalises a custom rule of type 'http' into a
          // native http rule, so a template that declares `custom` describes a
          // resource that can never match what the service stores. The
          // idempotency what-if showed exactly that, on a deployment that had
          // changed nothing:
          //
          //   ~ properties.template.scale.rules: [
          //     ~ 0:
          //       - http:   metadata.concurrentRequests: "50"
          //       + custom: metadata.concurrentRequests: "50", type: "http"
          //
          // Permanent drift, reported forever, on a resource that is correct.
          // That is how a team learns to ignore what-if output — and ignoring
          // it is how the real change hides.
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
