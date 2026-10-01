targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Prefix applied to every resource name.')
param namePrefix string = 'sabansal-ilb-routing-two-infra'

@description('Administrator user name for all VMs.')
param adminUsername string = 'azureuser'

@description('SSH public key used by all VMs.')
@secure()
param adminPublicKey string

@description('Azure Linux 4 VM size. This default requires NVMe.')
param vmSize string = 'Standard_D2als_v7'

param vnetAddressPrefix string = '10.80.0.0/16'
param routerSubnetPrefix string = '10.80.0.0/24'
param vm1SubnetPrefix string = '10.80.1.0/24'
param vm2SubnetPrefix string = '10.80.2.0/24'

param ilbFrontendIp string = '10.80.0.10'
param router1PrimaryIp string = '10.80.0.4'
param router1SecondaryIp string = '10.80.0.5'
param router2PrimaryIp string = '10.80.0.6'
param vm1PrivateIp string = '10.80.1.4'
param vm2PrivateIp string = '10.80.2.4'

var vm1Name = '${namePrefix}-vm1'
var vm2Name = '${namePrefix}-vm2'
var router1Name = '${namePrefix}-router1'
var router2Name = '${namePrefix}-router2'
var loadBalancerName = '${namePrefix}-ilb'
var backendPoolName = 'router-backend'
var frontendName = 'frontend'
var probeName = 'ssh-health'

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
    name: 'AllowAzureLoadBalancerInbound'
    properties: {
      access: 'Allow'
      direction: 'Inbound'
      priority: 130
      protocol: '*'
      sourceAddressPrefix: 'AzureLoadBalancer'
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

resource vm1RouteTable 'Microsoft.Network/routeTables@2024-05-01' = {
  name: '${vm1Name}-rt'
  location: location
  properties: {
    disableBgpRoutePropagation: false
    routes: [
      {
        name: 'to-vm2-via-ilb'
        properties: {
          addressPrefix: vm2SubnetPrefix
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: ilbFrontendIp
        }
      }
    ]
  }
}

resource vm2RouteTable 'Microsoft.Network/routeTables@2024-05-01' = {
  name: '${vm2Name}-rt'
  location: location
  properties: {
    disableBgpRoutePropagation: false
    routes: [
      {
        name: 'to-vm1-via-ilb'
        properties: {
          addressPrefix: vm1SubnetPrefix
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: ilbFrontendIp
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

resource loadBalancer 'Microsoft.Network/loadBalancers@2024-05-01' = {
  name: loadBalancerName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    frontendIPConfigurations: [
      {
        name: frontendName
        properties: {
          privateIPAddress: ilbFrontendIp
          privateIPAllocationMethod: 'Static'
          subnet: {
            id: vnet.properties.subnets[0].id
          }
        }
      }
    ]
    backendAddressPools: [
      {
        name: backendPoolName
      }
    ]
    probes: [
      {
        name: probeName
        properties: {
          protocol: 'Tcp'
          port: 22
          intervalInSeconds: 5
          numberOfProbes: 2
        }
      }
    ]
    loadBalancingRules: [
      {
        name: 'ha-ports'
        properties: {
          protocol: 'All'
          frontendPort: 0
          backendPort: 0
          enableFloatingIP: true
          disableOutboundSnat: true
          idleTimeoutInMinutes: 30
          loadDistribution: 'Default'
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', loadBalancerName, frontendName)
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', loadBalancerName, backendPoolName)
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', loadBalancerName, probeName)
          }
        }
      }
    ]
  }
}

resource backendPool 'Microsoft.Network/loadBalancers/backendAddressPools@2024-05-01' = {
  parent: loadBalancer
  name: backendPoolName
  properties: {
    loadBalancerBackendAddresses: [
      {
        name: 'active-router-secondary'
        properties: {
          adminState: 'Up'
          virtualNetwork: {
            id: vnet.id
          }
          ipAddress: router1SecondaryIp
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
    secondaryPrivateIpAddress: router1SecondaryIp
    sharedBackendIpAddress: router1SecondaryIp
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
output loadBalancerName string = loadBalancer.name
output loadBalancerFrontendIp string = ilbFrontendIp
output backendPoolName string = backendPoolName
output backendPoolIp string = router1SecondaryIp
output virtualNetworkName string = vnet.name
output vm1Name string = vm1.outputs.vmName
output vm1NicName string = vm1.outputs.nicName
output vm1PrivateIp string = vm1PrivateIp
output vm1SubnetPrefix string = vm1SubnetPrefix
output vm2Name string = vm2.outputs.vmName
output vm2NicName string = vm2.outputs.nicName
output vm2PrivateIp string = vm2PrivateIp
output vm2SubnetPrefix string = vm2SubnetPrefix
output router1Name string = router1.outputs.vmName
output router1NicName string = router1.outputs.nicName
output router1PrimaryIp string = router1PrimaryIp
output router1SecondaryIp string = router1SecondaryIp
output router2Name string = router2.outputs.vmName
output router2NicName string = router2.outputs.nicName
output router2PrimaryIp string = router2PrimaryIp
