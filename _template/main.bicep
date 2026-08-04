targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Prefix applied to every resource name.')
param namePrefix string = 'topo'

// Add modules here, for example:
// module network 'modules/network.bicep' = {
//   name: 'network'
//   params: {
//     location: location
//     vnetName: '${namePrefix}-vnet'
//   }
// }

output namePrefix string = namePrefix
output location string = location
