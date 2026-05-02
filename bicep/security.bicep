@description('Azure region for the Key Vault.')
param location string = 'centralus'

@description('Tags applied to the Key Vault.')
param tags object = {
  env: 'lab'
}

@description('Home public IP address (no CIDR suffix; /32 is implied). Allowlisted on the KV network ACL.')
param homeIp string

@description('Object ID of the admin user (Entra ID). Granted Key Vault Secrets Officer.')
param adminObjectId string = ''

@description('Object ID of the automation service principal. Granted Key Vault Secrets User.')
param automationObjectId string = ''

// Vault name: deterministic 6-char suffix from subscription ID, matching the bash convention
var keyVaultName = 'kv-lab-${substring(replace(subscription().subscriptionId, '-', ''), 0, 6)}'

// Built-in Key Vault RBAC role definition GUIDs
var roleSecretsOfficer = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
var roleSecretsUser = '4633458b-17de-408a-b874-0445c86b69e6'

resource kv 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      name: 'standard'
      family: 'A'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      ipRules: [
        {
          value: homeIp
        }
      ]
      virtualNetworkRules: []
    }
  }
}

resource adminAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(adminObjectId)) {
  name: guid(kv.id, adminObjectId, roleSecretsOfficer)
  scope: kv
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleSecretsOfficer)
    principalId: adminObjectId
    principalType: 'User'
  }
}

resource automationAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(automationObjectId)) {
  name: guid(kv.id, automationObjectId, roleSecretsUser)
  scope: kv
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleSecretsUser)
    principalId: automationObjectId
    principalType: 'ServicePrincipal'
  }
}

output keyVaultId string = kv.id
output keyVaultName string = kv.name
output keyVaultUri string = kv.properties.vaultUri
