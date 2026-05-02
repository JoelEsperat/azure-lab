@description('Azure region for the subnet router resources.')
param location string = 'centralus'

@description('Tags applied to all resources.')
param tags object = {
  env: 'lab'
}

@description('Existing VNet to attach the NIC to.')
param vnetName string = 'vnet-lab'

@description('Existing subnet within the VNet.')
param subnetName string = 'snet-gateway'

@description('Static private IP for the subnet router NIC.')
param privateIpAddress string = '10.0.0.10'

@description('VM size. Must be allowed by the Allowed VM SKUs policy.')
param vmSize string = 'Standard_B2pts_v2'

@description('Admin username on the VM.')
param adminUsername string = 'azureuser'

@description('SSH public key for the admin user.')
@secure()
param adminSshPubkey string

@description('Tailscale auth key (one-time, expires).')
@secure()
param tsAuthKey string

var cloudInit = base64(replace(loadTextContent('../tailscale/cloud-init.yaml'), '\${TS_AUTHKEY}', tsAuthKey))
var lawName   = 'law-lab-${substring(replace(subscription().subscriptionId, '-', ''), 0, 6)}'

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: lawName
  scope: resourceGroup('rg-lab-monitoring')
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  name: '${vnetName}/${subnetName}'
}

resource pip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-tailscale'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-tailscale'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowSSH-VNet'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: privateIpAddress
          destinationPortRange: '22'
        }
      }
    ]
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'nic-tailscale'
  location: location
  tags: tags
  properties: {
    networkSecurityGroup: {
      id: nsg.id
    }
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: subnet.id
          }
          privateIPAddress: privateIpAddress
          privateIPAllocationMethod: 'Static'
          publicIPAddress: {
            id: pip.id
          }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: 'vm-tailscale'
  location: location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server-arm64'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
        deleteOption: 'Delete'
      }
    }
    osProfile: {
      computerName: 'tailscale'
      adminUsername: adminUsername
      customData: cloudInit
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminSshPubkey
            }
          ]
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
}

resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: 'dcr-tailscale-vm'
  location: location
  tags: tags
  properties: {
    dataSources: {
      syslog: [
        {
          name: 'syslog-auth'
          streams: ['Microsoft-Syslog']
          facilityNames: ['auth', 'authpriv']
          // Info and above: captures successful SSH logins as well as failures
          logLevels: ['Info', 'Notice', 'Warning', 'Error', 'Critical', 'Alert', 'Emergency']
        }
        {
          name: 'syslog-system'
          streams: ['Microsoft-Syslog']
          facilityNames: ['daemon', 'syslog', 'kern']
          logLevels: ['Warning', 'Error', 'Critical', 'Alert', 'Emergency']
        }
      ]
      performanceCounters: [
        {
          name: 'perf-basic'
          streams: ['Microsoft-Perf']
          samplingFrequencyInSeconds: 60
          counterSpecifiers: [
            'Processor(*)\\% Processor Time'
            'Memory\\Available MBytes Memory'
            'LogicalDisk(*)\\% Free Space'
            'Network Interface(*)\\Total Bytes Transmitted'
            'Network Interface(*)\\Total Bytes Received'
          ]
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          name: 'law-dest'
          workspaceResourceId: law.id
        }
      ]
    }
    dataFlows: [
      {
        streams: ['Microsoft-Syslog']
        destinations: ['law-dest']
      }
      {
        streams: ['Microsoft-Perf']
        destinations: ['law-dest']
      }
    ]
  }
}

resource amaExtension 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: vm
  name: 'AzureMonitorLinuxAgent'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorLinuxAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
}

resource dcrAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
  name: 'dcra-tailscale-vm'
  scope: vm
  properties: {
    dataCollectionRuleId: dcr.id
  }
  dependsOn: [amaExtension]
}

resource nsgDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-nsg'
  scope: nsg
  properties: {
    workspaceId: law.id
    logs: [
      {
        category: 'NetworkSecurityGroupEvent'
        enabled: true
      }
      {
        category: 'NetworkSecurityGroupRuleCounter'
        enabled: true
      }
    ]
  }
}

output publicIp string = pip.properties.ipAddress
output vmName string = vm.name
