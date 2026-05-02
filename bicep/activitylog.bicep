targetScope = 'subscription'

@description('Tags applied to diagnostic settings (informational only).')
param tags object = {
  env: 'lab'
}

var lawName = 'law-lab-${substring(replace(subscription().subscriptionId, '-', ''), 0, 6)}'

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: lawName
  scope: resourceGroup('rg-lab-monitoring')
}

// Routes the subscription Activity Log to the Log Analytics workspace.
// Captures resource lifecycle events (create/update/delete), policy evaluations,
// security alerts, service health, and resource health changes.
resource activityLogDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-activity-log'
  scope: subscription()
  properties: {
    workspaceId: law.id
    logs: [
      {
        category: 'Administrative'
        enabled: true
      }
      {
        category: 'Security'
        enabled: true
      }
      {
        category: 'ServiceHealth'
        enabled: true
      }
      {
        category: 'Alert'
        enabled: true
      }
      {
        category: 'Recommendation'
        enabled: true
      }
      {
        category: 'Policy'
        enabled: true
      }
      {
        category: 'ResourceHealth'
        enabled: true
      }
      {
        category: 'Autoscale'
        enabled: false
      }
    ]
  }
}
