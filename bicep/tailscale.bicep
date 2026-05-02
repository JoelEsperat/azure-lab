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

// Cloud-init template loaded at compile time; auth key substituted at deploy time
var cloudInit = base64(replace(loadTextContent('../tailscale/cloud-init.yaml'), '\${TS_AUTHKEY}', tsAuthKey))

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

output publicIp string = pip.properties.ipAddress
output vmName string = vm.name
