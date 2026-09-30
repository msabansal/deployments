@description('Azure region for all resources.')
param location string

@description('Name of the virtual network.')
param vnetName string

@description('Address space of the virtual network.')
param vnetAddressPrefix string

@description('Address prefix of the forwarding (router) subnet.')
param routerSubnetPrefix string

@description('Address prefix of the subnet hosting endpoint A.')
param endpointASubnetPrefix string

@description('Address prefix of the subnet hosting endpoint B.')
param endpointBSubnetPrefix string

@description('Static private IP of the router VM. User-defined routes point at this address.')
param routerPrivateIpAddress string

@description('First port of the test traffic range opened in the NSGs.')
param testPortRangeStart int

@description('Last port of the test traffic range opened in the NSGs.')
param testPortRangeEnd int

var testPortRange = '${testPortRangeStart}-${testPortRangeEnd}'

var baselineInboundRules = [
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
    name: 'AllowTestPortRangeInbound'
    properties: {
      access: 'Allow'
      direction: 'Inbound'
      priority: 120
      protocol: '*'
      sourceAddressPrefix: vnetAddressPrefix
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: testPortRange
    }
  }
  {
    name: 'AllowVirtualNetworkInbound'
    properties: {
      access: 'Allow'
      direction: 'Inbound'
      priority: 130
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
  name: '${vnetName}-endpoint-nsg'
  location: location
  properties: {
    securityRules: baselineInboundRules
  }
}

resource routerNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${vnetName}-router-nsg'
  location: location
  properties: {
    securityRules: baselineInboundRules
  }
}

resource endpointARouteTable 'Microsoft.Network/routeTables@2024-05-01' = {
  name: '${vnetName}-endpoint-a-rt'
  location: location
  properties: {
    disableBgpRoutePropagation: false
    routes: [
      {
        name: 'to-endpoint-b-via-router'
        properties: {
          addressPrefix: endpointBSubnetPrefix
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: routerPrivateIpAddress
        }
      }
    ]
  }
}

resource endpointBRouteTable 'Microsoft.Network/routeTables@2024-05-01' = {
  name: '${vnetName}-endpoint-b-rt'
  location: location
  properties: {
    disableBgpRoutePropagation: false
    routes: [
      {
        name: 'to-endpoint-a-via-router'
        properties: {
          addressPrefix: endpointASubnetPrefix
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: routerPrivateIpAddress
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
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
        name: 'endpoint-a'
        properties: {
          addressPrefix: endpointASubnetPrefix
          networkSecurityGroup: {
            id: endpointNsg.id
          }
          routeTable: {
            id: endpointARouteTable.id
          }
        }
      }
      {
        name: 'endpoint-b'
        properties: {
          addressPrefix: endpointBSubnetPrefix
          networkSecurityGroup: {
            id: endpointNsg.id
          }
          routeTable: {
            id: endpointBRouteTable.id
          }
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output routerSubnetId string = vnet.properties.subnets[0].id
output endpointASubnetId string = vnet.properties.subnets[1].id
output endpointBSubnetId string = vnet.properties.subnets[2].id
