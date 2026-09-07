// Azure Service Bus topology: namespace, topic, subscriptions, rules, RBAC.
//
// PROVENANCE: this is Day 19's Day19/infra/servicebus.bicep, moved here and
// parameterized. It was written for the topics/DLQ exercise and then left
// orphaned — nothing referenced it, so it described a topology that no
// deployment ever created. Day 23 wires it into the graph. Day 19's comments
// are kept verbatim wherever the code they explain is unchanged, because they
// explain traps rather than syntax.
//
// WHY BICEP OWNS THIS (not the application):
// An app that creates its own topics needs Manage rights in production, which is
// exactly the right it should not have. Infrastructure declares the topology;
// the app only gets Sender on the topic and Receiver on the subscriptions.
//
// WHAT DAY 23 CHANGED: sku, TTL, lock duration, delivery count, the namespace
// name and the subscription names are parameters now. The two subscriptions are
// still declared explicitly rather than generated from an array — one of them
// carries a filter rule and the other deliberately does not, and a loop that
// has to express "except this one" is not simpler than two resources that say
// what they are. Generality was available; clarity was worth more.
//
// And one thing Day 23 REMOVED: the '$Default' rule Day 19 declared as `1=0`.
// See the comment above contentChangesRule — deploying the file is what showed
// the reasoning behind it to be wrong.

targetScope = 'resourceGroup'

@description('Name of the Service Bus namespace. Globally unique.')
@minLength(6)
@maxLength(50)
param namespaceName string

@description('Location for all resources.')
param location string

@description('Tags applied to the namespace.')
param tags object

@description('SKU. Basic has QUEUES ONLY — topics and subscriptions require Standard or Premium, which is why Basic is not representable here.')
@allowed([
  'Standard'
  'Premium'
])
param skuName string = 'Standard'

@description('Messaging units. Premium only; ignored on Standard.')
@allowed([
  1
  2
  4
  8
  16
])
param messagingUnits int = 1

@description('Name of the topic.')
param topicName string = 'quote-events'

@description('Message TTL, ISO 8601. Bounds the "unbounded bill" risk: an unread subscription accumulates at most this much, not everything since the beginning of time.')
param defaultMessageTimeToLive string = 'P7D'

@description('Deliveries before a message is dead-lettered. The service default of 10 hides a poison message behind ten attempts.')
@minValue(1)
@maxValue(100)
param maxDeliveryCount int = 3

@description('Lock duration, ISO 8601, max PT5M. Long enough for the handler, short enough that a crashed consumer releases the message quickly.')
param lockDuration string = 'PT1M'

@description('Name of the subscription that receives every event type.')
param auditSubscriptionName string = 'audit'

@description('Name of the filtered subscription.')
param searchIndexSubscriptionName string = 'search-index'

@description('SQL filter for the filtered subscription.')
param searchIndexFilter string = 'eventType IN (\'QuoteCreated\',\'QuoteUpdated\')'

@description('Principal ID of the application managed identity that needs send/receive rights.')
param appPrincipalId string

var skuConfig = skuName == 'Premium'
  ? {
      name: 'Premium'
      tier: 'Premium'
      capacity: messagingUnits
    }
  : {
      name: 'Standard'
      tier: 'Standard'
    }

resource serviceBusNamespace 'Microsoft.ServiceBus/namespaces@2022-10-01-preview' = {
  name: namespaceName
  location: location
  tags: tags
  sku: skuConfig
  properties: {
    // Disable local (SAS) auth: managed identity only.
    // The app carries DefaultAzureCredential; no connection string anywhere.
    disableLocalAuth: true
  }
}

resource topic 'Microsoft.ServiceBus/namespaces/topics@2022-10-01-preview' = {
  name: topicName
  parent: serviceBusNamespace
  properties: {
    defaultMessageTimeToLive: defaultMessageTimeToLive

    // Duplicate detection OFF (deliberate). Broker-side dup detection protects
    // against a publisher sending twice; it does NOT protect the consumer
    // against redelivery after a lock expiry or crash. The consumer-side
    // ProcessedMessages table is the guarantee that actually holds — see the
    // Day 20 outbox write-up, at-least-once delivery with exactly-once effect.
    requiresDuplicateDetection: false

    enableBatchedOperations: true
    supportOrdering: false
  }
}

// Subscription: audit — receives ALL event types via the default TrueFilter.
resource auditSubscription 'Microsoft.ServiceBus/namespaces/topics/subscriptions@2022-10-01-preview' = {
  name: auditSubscriptionName
  parent: topic
  properties: {
    maxDeliveryCount: maxDeliveryCount
    lockDuration: lockDuration
    defaultMessageTimeToLive: defaultMessageTimeToLive

    // An expired audit event should be inspectable (and potentially replayed),
    // not silently dropped.
    deadLetteringOnMessageExpiration: true

    enableBatchedOperations: true
  }
}

// The audit subscription keeps the default '$Default' TrueFilter, which Service
// Bus adds automatically. No rule resource needed.

// Subscription: search-index — Created + Updated only, not Deleted.
resource searchIndexSubscription 'Microsoft.ServiceBus/namespaces/topics/subscriptions@2022-10-01-preview' = {
  name: searchIndexSubscriptionName
  parent: topic
  properties: {
    maxDeliveryCount: maxDeliveryCount
    lockDuration: lockDuration
    defaultMessageTimeToLive: defaultMessageTimeToLive
    deadLetteringOnMessageExpiration: true
    enableBatchedOperations: true
  }
}

// DAY 19'S PREMISE WAS WRONG, AND THIS DEPLOYMENT DISPROVED IT.
//
// Day 19 declared a '$Default' rule redefined as `1=0`, on the stated reasoning
// that "adding a rule does NOT replace '$Default'" and that a subscription
// carrying both would match everything. That template was never deployed —
// nothing referenced it — so the reasoning was never tested.
//
// It does not survive contact. Service Bus deletes the default rule when the
// first explicit rule is added to a subscription. The evidence is the
// idempotency what-if, run against resources this template had just created and
// not touched since:
//
//   + .../subscriptions/search-index/rules/$Default
//       properties.sqlFilter.sqlExpression: "1=0"
//
// '$Default' shows as a CREATE because it does not exist: ARM created it, then
// creating 'content-changes-only' made the service delete it. Every deployment
// would recreate it and every deployment would lose it again — permanent drift,
// declared forever, for a rule that cannot persist and would do nothing if it
// did.
//
// So it is gone. One rule on the subscription, and the default removes itself.
// The 'audit' subscription keeps its '$Default' TrueFilter precisely because it
// has no explicit rule — which is the same behaviour seen from the other side,
// and is what makes audit receive everything.
resource contentChangesRule 'Microsoft.ServiceBus/namespaces/topics/subscriptions/rules@2022-10-01-preview' = {
  name: 'content-changes-only'
  parent: searchIndexSubscription
  properties: {
    filterType: 'SqlFilter'
    sqlFilter: {
      sqlExpression: searchIndexFilter
    }
  }
}

// RBAC: the managed identity gets Sender on the topic and Receiver on the
// subscriptions. No connection strings, no shared-access policies on the app
// side. Least privilege in the literal sense — Sender cannot read, Receiver
// cannot publish, and neither can create a topic.
var senderRoleId = '69a216fc-b8fb-44d8-bc22-1f3c2cd27a39' // Azure Service Bus Data Sender
var receiverRoleId = '4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0' // Azure Service Bus Data Receiver

resource topicSenderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(serviceBusNamespace.id, appPrincipalId, senderRoleId)
  scope: topic
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', senderRoleId)
    principalId: appPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource auditReceiverRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(serviceBusNamespace.id, appPrincipalId, receiverRoleId, 'audit')
  scope: auditSubscription
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', receiverRoleId)
    principalId: appPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource searchIndexReceiverRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(serviceBusNamespace.id, appPrincipalId, receiverRoleId, 'search-index')
  scope: searchIndexSubscription
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', receiverRoleId)
    principalId: appPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Consumed by the app's configuration pipeline — these are the exact values
// ServiceBus:FullyQualifiedNamespace, :TopicName, :AuditSubscription and
// :SearchIndexSubscription in appsettings.json.
output namespaceFqdn string = '${serviceBusNamespace.name}.servicebus.windows.net'
output topicName string = topic.name
output auditSubscriptionName string = auditSubscription.name
output searchIndexSubscriptionName string = searchIndexSubscription.name
