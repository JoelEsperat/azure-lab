@description('Tags applied to the action group.')
param tags object = {
  env: 'lab'
}

@description('Email address that receives alerts from this action group.')
param adminEmail string

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

output actionGroupId string = actionGroup.id
output actionGroupName string = actionGroup.name
