param location string
param circuitName string
param serviceProviderName string
param peeringLocation string
param bandwidthInMbps int
param configurePrivatePeering bool
param peerAsn int
param vlanId int
param primaryPeerAddressPrefix string
param secondaryPeerAddressPrefix string

@secure()
param sharedKey string

resource circuit 'Microsoft.Network/expressRouteCircuits@2024-05-01' = {
  name: circuitName
  location: location
  sku: {
    name: 'Premium_MeteredData'
    tier: 'Premium'
    family: 'MeteredData'
  }
  properties: {
    allowClassicOperations: false
    serviceProviderProperties: {
      serviceProviderName: serviceProviderName
      peeringLocation: peeringLocation
      bandwidthInMbps: bandwidthInMbps
    }
  }
}

resource privatePeering 'Microsoft.Network/expressRouteCircuits/peerings@2024-05-01' = if (configurePrivatePeering) {
  name: 'AzurePrivatePeering'
  parent: circuit
  properties: {
    peeringType: 'AzurePrivatePeering'
    peerASN: peerAsn
    primaryPeerAddressPrefix: primaryPeerAddressPrefix
    secondaryPeerAddressPrefix: secondaryPeerAddressPrefix
    vlanId: vlanId
    sharedKey: sharedKey
  }
}

output circuitId string = circuit.id
output serviceKey string = circuit.properties.serviceKey
