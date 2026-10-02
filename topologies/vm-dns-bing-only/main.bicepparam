using 'main.bicep'

param vmName = 'vm-dns-bing-only'
param vnetAddressPrefix = '10.50.0.0/16'
param vmSubnetAddressPrefix = '10.50.0.0/24'
param resolverSubnetAddressPrefix = '10.50.1.0/28'
param resolverIpAddress = '10.50.1.4'
param adminUsername = 'azureuser'
param vmSize = 'Standard_D4d_v5'
param imageVersion = 'latest'

// Supplied at deploy time by deploy.ps1.
param location = ''
param adminPublicKey = ''
