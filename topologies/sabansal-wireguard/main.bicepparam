using 'main.bicep'

param namePrefix = 'sabansal-wireguard'
param vmSize = 'Standard_D2als_v7'
param vnetAddressPrefix = '10.70.0.0/16'
param subnetAddressPrefix = '10.70.0.0/24'
param serverPrivateIp = '10.70.0.4'
param clientPrivateIp = '10.70.0.5'
param adminUsername = 'azureuser'

// Supplied by deploy.ps1.
param location = 'westus3'
param adminPublicKey = ''
