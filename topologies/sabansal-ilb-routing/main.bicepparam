using 'main.bicep'

param namePrefix = 'sabansal-ilb-routing'
param location = 'westus3'
param adminUsername = 'azureuser'
param adminPublicKey = ''
param vmSize = 'Standard_D2als_v7'

param vnetAddressPrefix = '10.80.0.0/16'
param routerSubnetPrefix = '10.80.0.0/24'
param vm1SubnetPrefix = '10.80.1.0/24'
param vm2SubnetPrefix = '10.80.2.0/24'

param ilbFrontendIp = '10.80.0.10'
param router1PrimaryIp = '10.80.0.4'
param router1SecondaryIp = '10.80.0.5'
param router2PrimaryIp = '10.80.0.6'
param vm1PrivateIp = '10.80.1.4'
param vm2PrivateIp = '10.80.2.4'
