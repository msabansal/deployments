targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Prefix applied to every resource name.')
param namePrefix string = 'sabansal-ecmp-routing'

@description('Administrator user name for all VMs.')
param adminUsername string = 'azureuser'

@description('SSH public key used by all VMs.')
@secure()
param adminPublicKey string

@description('Azure Linux 4 VM size. This default requires NVMe.')
param vmSize string = 'Standard_D2als_v6'

param vnetAddressPrefix string = '10.81.0.0/16'
param routerSubnetPrefix string = '10.81.0.0/24'
param vm1SubnetPrefix string = '10.81.1.0/24'
param vm2SubnetPrefix string = '10.81.2.0/24'

param router1PrimaryIp string = '10.81.0.4'
param router2PrimaryIp string = '10.81.0.6'
param vm1PrivateIp string = '10.81.1.4'
param vm2PrivateIp string = '10.81.2.4'

var vm1Name = '${namePrefix}-vm1'
var vm2Name = '${namePrefix}-vm2'
var router1Name = '${namePrefix}-router1'
var router2Name = '${namePrefix}-router2'
var ecmpNextHopIps = [
  router1PrimaryIp
  router2PrimaryIp
]

var inboundRules = [
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
    name: 'AllowVirtualNetworkInbound'
    properties: {
      access: 'Allow'
      direction: 'Inbound'
      priority: 120
      protocol: '*'
      sourceAddressPrefix: 'VirtualNetwork'
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

resource endpointNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${namePrefix}-endpoint-nsg'
  location: location
  properties: {
    securityRules: inboundRules
  }
}

resource routerNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${namePrefix}-router-nsg'
  location: location
  properties: {
    securityRules: inboundRules
  }
}

resource vm1RouteTable 'Microsoft.Network/routeTables@2025-09-01' = {
  name: '${vm1Name}-rt'
  location: location
  properties: {
    disableBgpRoutePropagation: false
    routes: [
      {
        name: 'to-vm2-via-ecmp'
        properties: {
          addressPrefix: vm2SubnetPrefix
          nextHopType: 'VirtualApplianceEcmp'
          nextHop: {
            nextHopIpAddresses: ecmpNextHopIps
          }
        }
      }
    ]
  }
}

resource vm2RouteTable 'Microsoft.Network/routeTables@2025-09-01' = {
  name: '${vm2Name}-rt'
  location: location
  properties: {
    disableBgpRoutePropagation: false
    routes: [
      {
        name: 'to-vm1-via-ecmp'
        properties: {
          addressPrefix: vm1SubnetPrefix
          nextHopType: 'VirtualApplianceEcmp'
          nextHop: {
            nextHopIpAddresses: ecmpNextHopIps
          }
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
        name: 'router'
        properties: {
          addressPrefix: routerSubnetPrefix
          networkSecurityGroup: {
            id: routerNsg.id
          }
        }
      }
      {
        name: 'vm1'
        properties: {
          addressPrefix: vm1SubnetPrefix
          networkSecurityGroup: {
            id: endpointNsg.id
          }
          routeTable: {
            id: vm1RouteTable.id
          }
        }
      }
      {
        name: 'vm2'
        properties: {
          addressPrefix: vm2SubnetPrefix
          networkSecurityGroup: {
            id: endpointNsg.id
          }
          routeTable: {
            id: vm2RouteTable.id
          }
        }
      }
    ]
  }
}

module vm1 'modules/linux-vm.bicep' = {
  name: 'vm1'
  params: {
    location: location
    vmName: vm1Name
    subnetId: vnet.properties.subnets[1].id
    adminUsername: adminUsername
    adminPublicKey: adminPublicKey
    vmSize: vmSize
    primaryPrivateIpAddress: vm1PrivateIp
  }
}

module vm2 'modules/linux-vm.bicep' = {
  name: 'vm2'
  params: {
    location: location
    vmName: vm2Name
    subnetId: vnet.properties.subnets[2].id
    adminUsername: adminUsername
    adminPublicKey: adminPublicKey
    vmSize: vmSize
    primaryPrivateIpAddress: vm2PrivateIp
  }
}

module router1 'modules/linux-vm.bicep' = {
  name: 'router1'
  params: {
    location: location
    vmName: router1Name
    subnetId: vnet.properties.subnets[0].id
    adminUsername: adminUsername
    adminPublicKey: adminPublicKey
    vmSize: vmSize
    primaryPrivateIpAddress: router1PrimaryIp
    isRouter: true
  }
}

module router2 'modules/linux-vm.bicep' = {
  name: 'router2'
  params: {
    location: location
    vmName: router2Name
    subnetId: vnet.properties.subnets[0].id
    adminUsername: adminUsername
    adminPublicKey: adminPublicKey
    vmSize: vmSize
    primaryPrivateIpAddress: router2PrimaryIp
    isRouter: true
  }
}

output operatingSystem string = 'Azure Linux 4'
output virtualNetworkName string = vnet.name
output vm1RouteTableName string = vm1RouteTable.name
output vm1RouteName string = 'to-vm2-via-ecmp'
output vm2RouteTableName string = vm2RouteTable.name
output vm2RouteName string = 'to-vm1-via-ecmp'
output ecmpNextHopIps array = ecmpNextHopIps
output vm1Name string = vm1.outputs.vmName
output vm1NicName string = vm1.outputs.nicName
output vm1PrivateIp string = vm1PrivateIp
output vm1PublicIp string = vm1.outputs.publicIpAddress
output vm1SubnetPrefix string = vm1SubnetPrefix
output vm2Name string = vm2.outputs.vmName
output vm2NicName string = vm2.outputs.nicName
output vm2PrivateIp string = vm2PrivateIp
output vm2PublicIp string = vm2.outputs.publicIpAddress
output vm2SubnetPrefix string = vm2SubnetPrefix
output router1Name string = router1.outputs.vmName
output router1NicName string = router1.outputs.nicName
output router1PrimaryIp string = router1PrimaryIp
output router1PublicIp string = router1.outputs.publicIpAddress
output router2Name string = router2.outputs.vmName
output router2NicName string = router2.outputs.nicName
output router2PrimaryIp string = router2PrimaryIp
output router2PublicIp string = router2.outputs.publicIpAddress
