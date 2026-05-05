targetScope = 'subscription'

@description('Azure region for all resources.')
param location string = 'centralus'

@description('Tags applied to every resource group.')
param tags object = {
  env: 'lab'
}

resource rgNetwork 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-lab-network'
  location: location
  tags: tags
}

resource rgMonitoring 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-lab-monitoring'
  location: location
  tags: tags
}

resource rgSecurity 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-lab-security'
  location: location
  tags: tags
}

resource rgWorkloads 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-lab-workloads'
  location: location
  tags: tags
}

output rgNetworkName string = rgNetwork.name
output rgMonitoringName string = rgMonitoring.name
output rgSecurityName string = rgSecurity.name
output rgWorkloadsName string = rgWorkloads.name
