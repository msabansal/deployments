using 'main.bicep'

param namePrefix = 'sabansal-ecmp-routing'
param location = 'centralindia'
param adminUsername = 'azureuser'
param adminPublicKey = ''
param vmSize = 'Standard_D2als_v6'

param vnetAddressPrefix = '10.81.0.0/16'
param routerSubnetPrefix = '10.81.0.0/24'
param vm1SubnetPrefix = '10.81.1.0/24'
param vm2SubnetPrefix = '10.81.2.0/24'

param router1PrimaryIp = '10.81.0.4'
param router2PrimaryIp = '10.81.0.6'
param vm1PrivateIp = '10.81.1.4'
param vm2PrivateIp = '10.81.2.4'
