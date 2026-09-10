targetScope = 'resourceGroup'

@description('Azure region for all resources. Must support the selected VM size and image.')
param location string = resourceGroup().location

@description('Prefix applied to every resource name.')
@minLength(1)
@maxLength(40)
param namePrefix string = 'azlinux'

@description('Address space of the virtual network.')
param vnetAddressPrefix string = '10.40.0.0/16'

@description('Address prefix of the VM subnet.')
param subnetAddressPrefix string = '10.40.0.0/24'

@description('Administrator user name.')
param adminUsername string = 'azureuser'

@description('SSH public key used for the administrator account. Supply at deploy time.')
@secure()
param adminPublicKey string

@description('VM size. Standard_D4d_v5 provides 4 vCPUs and 16 GiB RAM. Must support the selected disk tier, controller, and Accelerated Networking.')
param vmSize string = 'Standard_D4d_v5'

@description('OS disk storage tier. Must be supported by the selected VM size.')
@allowed([
  'Standard_LRS'
  'StandardSSD_LRS'
  'Premium_LRS'
])
param osDiskStorageAccountType string = 'StandardSSD_LRS'

@description('Disk controller type. Must be supported by the selected VM size and image.')
@allowed([
  'SCSI'
  'NVMe'
])
param diskControllerType string = 'SCSI'

@description('Azure Linux 4 image version. Use latest for the newest published image at deployment time.')
param imageVersion string = 'latest'

@description('Public IP DNS label, unique within the Azure region. Use 3-63 lowercase letters, digits, or hyphens; start with a letter and end with a letter or digit.')
@minLength(3)
@maxLength(63)
param publicIpDnsLabel string = 'azlinux-${uniqueString(resourceGroup().id, namePrefix)}'

var vmName = '${namePrefix}-vm'

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${namePrefix}-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowCorpnetPublicInbound'
        properties: {
          access: 'Allow'
          direction: 'Inbound'
          priority: 100
          protocol: '*'
          sourceAddressPrefix: 'CorpnetPublic'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'AllowCorpnetSAWInbound'
        properties: {
          access: 'Allow'
          direction: 'Inbound'
          priority: 110
          protocol: '*'
          sourceAddressPrefix: 'CorpnetSAW'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'DenyAllOtherInbound'
        properties: {
          access: 'Deny'
          direction: 'Inbound'
          priority: 4096
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: '${namePrefix}-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: 'vm'
        properties: {
          addressPrefix: subnetAddressPrefix
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: '${vmName}-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    dnsSettings: {
      domainNameLabel: publicIpDnsLabel
    }
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${vmName}-nic'
  location: location
  properties: {
    enableAcceleratedNetworking: true
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: publicIp.id
          }
          subnet: {
            id: vnet.properties.subnets[0].id
          }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: {
            primary: true
          }
        }
      ]
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        provisionVMAgent: true
        ssh: {
          publicKeys: [
            {
              keyData: adminPublicKey
              path: '/home/${adminUsername}/.ssh/authorized_keys'
            }
          ]
        }
      }
    }
    storageProfile: {
      diskControllerType: diskControllerType
      imageReference: {
        publisher: 'MicrosoftAzureLinux'
        offer: 'azurelinux-4'
        sku: '4'
        version: imageVersion
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: osDiskStorageAccountType
        }
      }
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

output vmId string = vm.id
output vnetId string = vnet.id
output nsgId string = nsg.id
output privateIpAddress string = nic.properties.ipConfigurations[0].properties.privateIPAddress
output publicIpAddress string = publicIp.properties.ipAddress
output publicIpFqdn string = publicIp.properties.dnsSettings.fqdn
output sshCommand string = 'ssh ${adminUsername}@${publicIp.properties.dnsSettings.fqdn}'
