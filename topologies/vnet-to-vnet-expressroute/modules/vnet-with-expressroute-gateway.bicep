param location string
param deployVnet bool
param deployGateway bool
param vnetName string
param vnetAddressPrefix string
param workloadSubnetPrefix string
param gatewaySubnetPrefix string
param gatewayName string
param publicIpName string
param gatewaySku string

resource workloadNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${vnetName}-workload-nsg'
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
          priority: 130
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

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = if (deployVnet) {
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
        name: 'workload'
        properties: {
          addressPrefix: workloadSubnetPrefix
          networkSecurityGroup: {
            id: workloadNsg.id
          }
        }
      }
      {
        name: 'GatewaySubnet'
        properties: {
          addressPrefix: gatewaySubnetPrefix
        }
      }
    ]
  }
}

resource existingVnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
}

resource existingWorkloadSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  name: 'workload'
  parent: existingVnet
}

resource existingWorkloadSubnetUpdate 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = if (!deployVnet) {
  name: 'workload'
  parent: existingVnet
  properties: {
    addressPrefix: workloadSubnetPrefix
    networkSecurityGroup: {
      id: workloadNsg.id
    }
  }
}

resource gatewayPublicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = if (deployGateway) {
  name: publicIpName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource gateway 'Microsoft.Network/virtualNetworkGateways@2024-05-01' = if (deployGateway) {
  name: gatewayName
  location: location
  dependsOn: [
    vnet
  ]
  properties: {
    activeActive: false
    enableBgp: false
    gatewayType: 'ExpressRoute'
    allowRemoteVnetTraffic: true
    allowVirtualWanTraffic: true
    ipConfigurations: [
      {
        name: 'default'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: gatewayPublicIp.id
          }
          subnet: {
            id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'GatewaySubnet')
          }
        }
      }
    ]
    sku: {
      name: gatewaySku
      tier: gatewaySku
    }
    vpnType: 'RouteBased'
  }
}

output vnetId string = existingVnet.id
output gatewayId string = deployGateway ? gateway!.id : ''
output workloadSubnetId string = existingWorkloadSubnet.id
output workloadNsgId string = workloadNsg.id
