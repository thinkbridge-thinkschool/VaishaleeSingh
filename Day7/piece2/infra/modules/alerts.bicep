// ============================================================================
// Alerting — Day 26
// ============================================================================
// One action group and one scheduled query rule, on error rate.
//
// WHY A LOG ALERT AND NOT A METRIC ALERT. Application Insights exposes a
// "failed requests" metric, and a metric alert on it is cheaper and faster to
// evaluate. It is also the wrong instrument here, because it counts failures
// and this needs a RATIO: twenty failures out of two hundred thousand requests
// is a healthy service, and two failures out of three is an outage. A metric
// alert on a count fires on the first and misses the second. Expressing the
// condition as a query is what makes the denominator available.
//
// THE COST, STATED: a scheduled query rule is billed per evaluation and a
// metric alert largely is not. At one evaluation every five minutes that is
// small, and it is the price of alerting on the right number.

@description('Name of the scheduled query rule.')
param alertRuleName string

@description('Name of the action group the rule notifies.')
param actionGroupName string

@description('Short name shown in SMS and push notifications. Twelve characters maximum, enforced by Azure.')
@maxLength(12)
param actionGroupShortName string

@description('Where notifications go. An operator address, not a credential — but it is still personal data, so it lives in the parameter file rather than in this template.')
param alertEmailAddress string

@description('Resource ID of the Application Insights component the rule queries.')
param applicationInsightsId string

@description('Location for the rule. Action groups are always global.')
param location string

@description('Tags applied to both resources.')
param tags object

@description('Error-rate percentage above which the rule fires. Five percent of real traffic, sustained, is a genuine problem; the query itself refuses to report a rate at all below a minimum request count.')
param errorRateThresholdPct int = 5

@description('The alert query. Loaded from the same .kql file the operator runs by hand, so the alert and the investigation can never disagree.')
param alertQuery string

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: actionGroupName
  // Action groups are global resources. Passing a region here is not an error
  // that fails the deployment; it is silently ignored, which is worse.
  location: 'global'
  tags: tags
  properties: {
    groupShortName: actionGroupShortName
    enabled: true
    emailReceivers: [
      {
        name: 'operator'
        emailAddress: alertEmailAddress
        // The common alert schema. Without it, every alert type sends a
        // differently-shaped payload, and anything downstream that parses them
        // has to special-case each one. Costs nothing to turn on now and is a
        // migration later.
        useCommonAlertSchema: true
      }
    ]
  }
}

resource errorRateAlert 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = {
  name: alertRuleName
  location: location
  tags: tags
  properties: {
    displayName: 'QuotesApi error rate above ${errorRateThresholdPct}%'
    description: 'Fires when the share of failed requests exceeds ${errorRateThresholdPct}% over five minutes, measured against real traffic only: health probes are excluded and the query returns nothing below a minimum request count. See Day26/kql/03-error-rate.kql for why that floor is the whole design.'

    // Severity 2 = Warning. Not 0 or 1: this is a dev environment that scales
    // to zero and is redeployed several times a day. An alert whose severity
    // overstates its urgency gets muted exactly as fast as one that fires too
    // often, and for the same reason.
    severity: 2
    enabled: true

    scopes: [ applicationInsightsId ]

    // Evaluated every five minutes over a five-minute window: consecutive,
    // non-overlapping. A window longer than the frequency re-reads the same
    // failures on each pass and holds an alert open after the cause is gone.
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'

    criteria: {
      allOf: [
        {
          query: alertQuery

          // The rule thresholds on a COLUMN the query computes, rather than on
          // the number of rows returned. Row-count alerting would fire the
          // moment the query returns anything at all, which would make the
          // percentage in the query decorative.
          metricMeasureColumn: 'errorRatePct'
          timeAggregation: 'Average'
          operator: 'GreaterThan'
          threshold: errorRateThresholdPct

          // TWO CONSECUTIVE FAILING PERIODS, NOT ONE, and this is the second
          // guard after the query's minimum-volume floor. A single deployment
          // rolls a revision and can produce a brief burst of failures that
          // resolves itself in under a minute; requiring the condition to hold
          // across two evaluations filters those without hiding a real
          // outage, which by definition does not clear itself in five minutes.
          failingPeriods: {
            numberOfEvaluationPeriods: 2
            minFailingPeriodsToAlert: 2
          }
        }
      ]
    }

    // Resolve the alert automatically once the condition clears. Without this
    // it stays fired until someone closes it by hand, and a dashboard full of
    // stale alerts is one nobody reads.
    autoMitigate: true

    actions: {
      actionGroups: [ actionGroup.id ]
    }
  }
}

output actionGroupId string = actionGroup.id
output alertRuleName string = errorRateAlert.name
