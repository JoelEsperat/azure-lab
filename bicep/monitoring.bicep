@description('Azure region for the Log Analytics workspace.')
param location string = 'centralus'

@description('Tags applied to all resources.')
param tags object = {
  env: 'lab'
}

@description('Email address that receives alerts from this action group.')
param adminEmail string

var lawName = 'law-lab-${substring(replace(subscription().subscriptionId, '-', ''), 0, 6)}'

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-lab-alerts'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'lab-alerts'
    enabled: true
    emailReceivers: [
      {
        name: 'email-admin'
        emailAddress: adminEmail
        useCommonAlertSchema: false
      }
    ]
  }
}

// PerGB2018 (Pay-As-You-Go): first 5 GB/month free; homelab volume well under that threshold.
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: lawName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

output actionGroupId string = actionGroup.id
output actionGroupName string = actionGroup.name
output workspaceId string = law.id
output workspaceName string = law.name
