using 'main.bicep'

param namePrefix = 'fwd'

param vnetAddressPrefix = '10.30.0.0/16'
param routerSubnetPrefix = '10.30.0.0/24'
param endpointASubnetPrefix = '10.30.1.0/24'
param endpointBSubnetPrefix = '10.30.2.0/24'
param routerPrivateIpAddress = '10.30.0.4'

// AzureLinux or WindowsServer2022
param routerOs = 'AzureLinux'

param adminUsername = 'azureuser'

param endpointVmSize = 'Standard_D2s_v5'
param routerVmSize = 'Standard_D4s_v5'
param enableEndpointAcceleratedNetworking = false

param testPortRangeStart = 5000
param testPortRangeEnd = 6000

// Supplied at deploy time by deploy.ps1.
param location = ''
param adminPublicKey = ''
param routerAdminPassword = ''
