@description('Azure region for the storage account.')
param location string = 'centralus'

@description('Tags applied to the storage account.')
param tags object = {
  env: 'lab'
}

@description('Home public IP address (no CIDR suffix). Allowlisted on the storage network ACL.')
param homeIp string

var storageAccountName = 'stlab${substring(replace(subscription().subscriptionId, '-', ''), 0, 8)}'

resource snetWorkloads 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  name: 'vnet-lab/snet-workloads'
  scope: resourceGroup('rg-lab-network')
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    accessTier: 'Hot'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      ipRules: [
        {
          value: homeIp
          action: 'Allow'
        }
      ]
      virtualNetworkRules: [
        {
          id: snetWorkloads.id
          action: 'Allow'
        }
      ]
    }
  }
}

resource backupContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  name: '${storageAccount.name}/default/backup'
  properties: {
    publicAccess: 'None'
  }
}

output storageAccountId string = storageAccount.id
output storageAccountName string = storageAccount.name
