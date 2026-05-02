targetScope = 'subscription'

@description('Allowed VM SKUs (built-in policy parameter).')
param allowedVmSkus array = [
  'Standard_B1s'
  'Standard_B2pts_v2'
]

@description('Allowed Azure regions (built-in policy parameter).')
param allowedLocations array = [
  'centralus'
]

@description('Resource group name where public IPs are allowed (Tailscale subnet router).')
param publicIpExceptionRg string = 'rg-lab-network'

// ── Built-in policy definition IDs ───────────────────────────────────────────
var allowedSkusDefId = tenantResourceId('Microsoft.Authorization/policyDefinitions', 'cccc23c7-8427-4f53-ad12-b6a63eb452b3')
var requireTagDefId = tenantResourceId('Microsoft.Authorization/policyDefinitions', '1e30110a-5ceb-460c-a204-c1c3969c6d62')
var allowedLocationsDefId = tenantResourceId('Microsoft.Authorization/policyDefinitions', 'e56962a6-4747-49cd-b67b-bf8b01975c4c')

// ── Custom policy definition: Deny public IPs ────────────────────────────────
resource denyPublicIpsDef 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: 'deny-public-ips'
  properties: {
    displayName: 'Deny public IPs'
    description: 'Deny public IPs'
    mode: 'All'
    policyRule: {
      if: {
        field: 'type'
        equals: 'Microsoft.Network/publicIPAddresses'
      }
      then: {
        effect: 'Deny'
      }
    }
  }
}

// ── Policy assignments ───────────────────────────────────────────────────────
resource polAllowedVmSkus 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: 'pol-allowed-vm-skus'
  properties: {
    displayName: 'Allowed virtual machine size SKUs'
    policyDefinitionId: allowedSkusDefId
    enforcementMode: 'Default'
    parameters: {
      listOfAllowedSKUs: {
        value: allowedVmSkus
      }
    }
  }
}

resource polRequireEnvTag 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: 'pol-require-env-tag'
  properties: {
    displayName: 'Require a tag and its value on resources'
    policyDefinitionId: requireTagDefId
    enforcementMode: 'DoNotEnforce'
    parameters: {
      tagName: {
        value: 'env'
      }
      tagValue: {
        value: 'lab'
      }
    }
  }
}

resource polDenyPublicIps 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: 'pol-deny-public-ips'
  properties: {
    displayName: 'Deny public IPs'
    policyDefinitionId: denyPublicIpsDef.id
    enforcementMode: 'Default'
    notScopes: [
      subscriptionResourceId('Microsoft.Resources/resourceGroups', publicIpExceptionRg)
    ]
  }
}

resource polAllowedLocations 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: 'pol-allowed-locations'
  properties: {
    displayName: 'Allowed locations'
    policyDefinitionId: allowedLocationsDefId
    enforcementMode: 'Default'
    parameters: {
      listOfAllowedLocations: {
        value: allowedLocations
      }
    }
  }
}
