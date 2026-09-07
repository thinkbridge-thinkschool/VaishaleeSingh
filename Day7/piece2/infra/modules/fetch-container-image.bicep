// Reads the image a container app is ALREADY running.
//
// WHY THIS EXISTS — it closes a footgun the first what-if exposed.
//
// api.bicep falls back to a hello-world placeholder when no image name is
// supplied, because before the first `azd deploy` the app has to point at some
// image for the resource to be creatable at all. That fallback is correct
// exactly once. On every LATER deployment that does not carry an image name —
// any plain `az deployment sub create`, any infrastructure-only change — the
// same fallback silently rewrites a running app back to hello-world. The
// what-if for the first draft of this template showed precisely that:
//
//   ~ image: "cr....azurecr.io/quotes-api:azd-deploy-1786708976"
//         => "mcr.microsoft.com/azuredocs/aci-helloworld:latest"
//
// which is an outage, produced by an infrastructure change that touches
// nothing about the application.
//
// So the placeholder is now the third choice, not the second:
//   1. an explicitly supplied image name (azd, or a deliberate -p)
//   2. failing that, whatever the app is running right now
//   3. failing that — the app does not exist yet — the placeholder
//
// This is the pattern azd's own generated templates use, and it is a separate
// module for the reason they make it one: an `existing` reference to a resource
// that may not exist has to be isolated behind a module boundary so the rest of
// the template can consume its result through a safe dereference.

targetScope = 'resourceGroup'

@description('Whether the container app already exists. False short-circuits the lookup.')
param exists bool

@description('Name of the container app to read.')
param containerAppName string

resource existingApp 'Microsoft.App/containerApps@2023-05-01' existing = if (exists) {
  name: containerAppName
}

// `existingApp.?properties` rather than `exists ? existingApp.properties ...`:
// a conditional `existing` resource has type `Microsoft.App/containerApps |
// null`, and Bicep will not accept a plain ternary as proof that the null
// branch is unreachable (BCP318). The safe-dereference operator propagates the
// null, and `??` turns it into the empty array the caller already handles.
output containers array = existingApp.?properties.template.containers ?? []
