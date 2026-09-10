targetScope = 'resourceGroup'

@description('Azure region for all regional resources.')
param location string = resourceGroup().location

@description('Prefix used for deployed resource names.')
param namePrefix string = 'vnet-to-vnet-er'

@description('Address space for the simulated on-premises virtual network.')
param onPremVnetAddressPrefix string = '10.0.0.0/16'

@description('Workload subnet prefix for the simulated on-premises virtual network.')
param onPremWorkloadSubnetPrefix string = '10.0.0.0/24'

@description('GatewaySubnet prefix for the simulated on-premises virtual network. Use /27 or larger for UltraPerformance.')
param onPremGatewaySubnetPrefix string = '10.0.255.224/27'

@description('Address space for the Azure virtual network.')
param azureVnetAddressPrefix string = '10.1.0.0/16'

@description('Workload subnet prefix for the Azure virtual network.')
param azureWorkloadSubnetPrefix string = '10.1.0.0/24'

@description('GatewaySubnet prefix for the Azure virtual network. Use /27 or larger for UltraPerformance.')
param azureGatewaySubnetPrefix string = '10.1.255.224/27'

@allowed([
  'ErGw1AZ'
  'ErGw2AZ'
  'ErGw3AZ'
  'Standard'
  'HighPerformance'
  'UltraPerformance'
])
@description('ExpressRoute virtual network gateway SKU.')
param gatewaySku string = 'ErGw1AZ'

@description('ExpressRoute circuit service provider.')
param serviceProviderName string = 'bvtazureixp03'

@description('ExpressRoute circuit peering location.')
param peeringLocation string = 'Noida2'

@minValue(50)
@description('Circuit bandwidth in Mbps.')
param bandwidthInMbps int = 1000

@description('Configure Azure private peering.')
param configurePrivatePeering bool = true

@description('Customer or simulated on-premises BGP ASN for Azure private peering.')
param peerAsn int = 65001

@description('VLAN ID allocated for Azure private peering.')
param vlanId int = 100

@description('Primary /30 IPv4 subnet used for the private peering BGP session.')
param primaryPeerAddressPrefix string = '192.168.0.0/30'

@description('Secondary /30 IPv4 subnet used for the private peering BGP session.')
param secondaryPeerAddressPrefix string = '192.168.0.4/30'

@secure()
@description('Optional MD5 key for Azure private peering.')
param peeringSharedKey string = ''

@description('Create the two circuit-to-gateway connections.')
param createConnections bool = true

@description('Enable ExpressRoute FastPath on both connections. Requires ErGw3AZ or UltraPerformance; ErGw1AZ and ErGw2AZ are not supported.')
param enableFastPath bool = false

@description('Create both virtual networks. When false, the named VNets and their workload and GatewaySubnet subnets must already exist; gateways, NSGs, VMs, and connections are still deployed.')
param deployVirtualNetworks bool = true

@description('Deploy both ExpressRoute gateways, the circuit, private peering, and gateway-to-circuit connections.')
param deployGatewaysAndCircuit bool = true

@description('Deploy one Azure Linux connectivity-test VM in each VNet.')
param deployTestVms bool = false

@description('Azure Linux VM administrator username.')
param testVmAdminUsername string = 'azureuser'

@secure()
@description('SSH public key used by the Azure Linux test VMs. Required when deployTestVms is true.')
param testVmAdminPublicKey string = ''

@description('Size used for both Azure Linux test VMs.')
param testVmSize string = 'Standard_D2s_v5'

module onPremNetwork 'modules/vnet-with-expressroute-gateway.bicep' = {
  name: 'onPremNetwork'
  params: {
    location: location
    deployVnet: deployVirtualNetworks
    deployGateway: deployGatewaysAndCircuit
    vnetName: '${namePrefix}-onprem-vnet'
    vnetAddressPrefix: onPremVnetAddressPrefix
    workloadSubnetPrefix: onPremWorkloadSubnetPrefix
    gatewaySubnetPrefix: onPremGatewaySubnetPrefix
    gatewayName: '${namePrefix}-onprem-gateway'
    publicIpName: '${namePrefix}-onprem-gateway-pip'
    gatewaySku: gatewaySku
  }
}

module azureNetwork 'modules/vnet-with-expressroute-gateway.bicep' = {
  name: 'azureNetwork'
  params: {
    location: location
    deployVnet: deployVirtualNetworks
    deployGateway: deployGatewaysAndCircuit
    vnetName: '${namePrefix}-azure-vnet'
    vnetAddressPrefix: azureVnetAddressPrefix
    workloadSubnetPrefix: azureWorkloadSubnetPrefix
    gatewaySubnetPrefix: azureGatewaySubnetPrefix
    gatewayName: '${namePrefix}-azure-gateway'
    publicIpName: '${namePrefix}-azure-gateway-pip'
    gatewaySku: gatewaySku
  }
}

module expressRoute 'modules/expressroute-circuit.bicep' = if (deployGatewaysAndCircuit) {
  name: 'expressRouteCircuit'
  params: {
    location: location
    circuitName: '${namePrefix}-circuit'
    serviceProviderName: serviceProviderName
    peeringLocation: peeringLocation
    bandwidthInMbps: bandwidthInMbps
    configurePrivatePeering: configurePrivatePeering
    peerAsn: peerAsn
    vlanId: vlanId
    primaryPeerAddressPrefix: primaryPeerAddressPrefix
    secondaryPeerAddressPrefix: secondaryPeerAddressPrefix
    sharedKey: peeringSharedKey
  }
}

module onPremTestVm 'modules/test-vm.bicep' = if (deployTestVms) {
  name: 'onPremTestVm'
  params: {
    location: location
    vmName: '${namePrefix}-onprem-vm'
    subnetId: onPremNetwork.outputs.workloadSubnetId
    peerWorkloadSubnetPrefix: azureWorkloadSubnetPrefix
    adminUsername: testVmAdminUsername
    adminPublicKey: testVmAdminPublicKey
    vmSize: testVmSize
  }
}

module azureTestVm 'modules/test-vm.bicep' = if (deployTestVms) {
  name: 'azureTestVm'
  params: {
    location: location
    vmName: '${namePrefix}-azure-vm'
    subnetId: azureNetwork.outputs.workloadSubnetId
    peerWorkloadSubnetPrefix: onPremWorkloadSubnetPrefix
    adminUsername: testVmAdminUsername
    adminPublicKey: testVmAdminPublicKey
    vmSize: testVmSize
  }
}

resource onPremConnection 'Microsoft.Network/connections@2024-05-01' = if (deployGatewaysAndCircuit && createConnections) {
  name: '${namePrefix}-onprem-to-circuit'
  location: location
  dependsOn: [
    azureNetwork
  ]
  properties: {
    connectionType: 'ExpressRoute'
    // The Network RP accepts ID-only references; Bicep's generated type incorrectly requires properties.
    #disable-next-line BCP035
    virtualNetworkGateway1: {
      id: onPremNetwork.outputs.gatewayId
    }
    #disable-next-line BCP035
    peer: {
      id: expressRoute!.outputs.circuitId
    }
    routingWeight: 0
    expressRouteGatewayBypass: enableFastPath
  }
}

resource azureConnection 'Microsoft.Network/connections@2024-05-01' = if (deployGatewaysAndCircuit && createConnections) {
  name: '${namePrefix}-azure-to-circuit'
  location: location
  dependsOn: [
    onPremNetwork
    onPremConnection
  ]
  properties: {
    connectionType: 'ExpressRoute'
    // The Network RP accepts ID-only references; Bicep's generated type incorrectly requires properties.
    #disable-next-line BCP035
    virtualNetworkGateway1: {
      id: azureNetwork.outputs.gatewayId
    }
    #disable-next-line BCP035
    peer: {
      id: expressRoute!.outputs.circuitId
    }
    routingWeight: 0
    expressRouteGatewayBypass: enableFastPath
  }
}

output circuitId string = deployGatewaysAndCircuit ? expressRoute!.outputs.circuitId : ''
output circuitServiceKey string = deployGatewaysAndCircuit ? expressRoute!.outputs.serviceKey : ''
output onPremGatewayId string = deployGatewaysAndCircuit ? onPremNetwork.outputs.gatewayId : ''
output azureGatewayId string = deployGatewaysAndCircuit ? azureNetwork.outputs.gatewayId : ''
output onPremTestVmPrivateIp string = deployTestVms ? onPremTestVm!.outputs.privateIpAddress : ''
output azureTestVmPrivateIp string = deployTestVms ? azureTestVm!.outputs.privateIpAddress : ''
output onPremTestVmPublicIp string = deployTestVms ? onPremTestVm!.outputs.publicIpAddress : ''
output azureTestVmPublicIp string = deployTestVms ? azureTestVm!.outputs.publicIpAddress : ''
