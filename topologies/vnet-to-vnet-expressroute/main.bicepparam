using './main.bicep'

param location = ''
param namePrefix = 'vnet-to-vnet-er'

param serviceProviderName = 'bvtazureixp03'
param peeringLocation = 'Noida2'
param bandwidthInMbps = 1000

param onPremVnetAddressPrefix = '10.0.0.0/16'
param onPremWorkloadSubnetPrefix = '10.0.0.0/24'
param onPremGatewaySubnetPrefix = '10.0.255.224/27'

param azureVnetAddressPrefix = '10.1.0.0/16'
param azureWorkloadSubnetPrefix = '10.1.0.0/24'
param azureGatewaySubnetPrefix = '10.1.255.224/27'

param gatewaySku = 'ErGw1AZ'

// The BVT provider is expected to provision the circuit automatically.
param configurePrivatePeering = true
param createConnections = true

param peerAsn = 65001
param vlanId = 100
param primaryPeerAddressPrefix = '192.168.0.0/30'
param secondaryPeerAddressPrefix = '192.168.0.4/30'
param peeringSharedKey = ''

param enableFastPath = true

param deployVirtualNetworks = true
param deployGatewaysAndCircuit = true

// Set to true and provide an SSH public key to deploy one Azure Linux VM per VNet.
param deployTestVms = false
param testVmAdminUsername = 'azureuser'
param testVmAdminPublicKey = ''
param testVmSize = 'Standard_D2s_v5'
