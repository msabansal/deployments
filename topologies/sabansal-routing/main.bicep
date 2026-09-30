targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Prefix applied to every resource name.')
param namePrefix string = 'sabansal-routing'

@description('Address space of the virtual network.')
param vnetAddressPrefix string = '10.30.0.0/16'

@description('Address prefix of the forwarding (router) subnet.')
param routerSubnetPrefix string = '10.30.0.0/24'

@description('Address prefix of the subnet hosting endpoint A.')
param endpointASubnetPrefix string = '10.30.1.0/24'

@description('Address prefix of the subnet hosting endpoint B.')
param endpointBSubnetPrefix string = '10.30.2.0/24'

@description('Static private IP of the router VM. Must fall inside routerSubnetPrefix and cannot be one of the first four addresses of the subnet.')
param routerPrivateIpAddress string = '10.30.0.4'

@description('Administrator user name for every VM.')
param adminUsername string = 'azureuser'

@description('SSH public key used by the Linux VMs.')
@secure()
param adminPublicKey string

@description('Size of the two endpoint VMs.')
param endpointVmSize string = 'Standard_D2s_v5'

@description('Size of the router VM. Must support Accelerated Networking.')
param routerVmSize string = 'Standard_D4s_v5'

@description('Storage account type for the router OS disk. Set to an empty string to leave the property off the VM, which is required when redeploying over a router that has already been resized.')
param routerOsDiskStorageAccountType string = 'Premium_LRS'

@description('Enable Accelerated Networking on the endpoint VMs.')
param enableEndpointAcceleratedNetworking bool = false

@description('First port of the test traffic range opened in the NSGs and guest firewalls.')
@minValue(1)
@maxValue(65535)
param testPortRangeStart int = 5000

@description('Last port of the test traffic range opened in the NSGs and guest firewalls.')
@minValue(1)
@maxValue(65535)
param testPortRangeEnd int = 6000

var routerVmName = '${namePrefix}-router'

module network 'modules/network.bicep' = {
  name: 'network'
  params: {
    location: location
    vnetName: '${namePrefix}-vnet'
    vnetAddressPrefix: vnetAddressPrefix
    routerSubnetPrefix: routerSubnetPrefix
    endpointASubnetPrefix: endpointASubnetPrefix
    endpointBSubnetPrefix: endpointBSubnetPrefix
    routerPrivateIpAddress: routerPrivateIpAddress
    testPortRangeStart: testPortRangeStart
    testPortRangeEnd: testPortRangeEnd
  }
}

module vm1 'modules/linux-vm.bicep' = {
  name: 'vm1'
  params: {
    location: location
    vmName: '${namePrefix}-vm1'
    subnetId: network.outputs.endpointASubnetId
    adminUsername: adminUsername
    adminPublicKey: adminPublicKey
    vmSize: endpointVmSize
    enableAcceleratedNetworking: enableEndpointAcceleratedNetworking
    enableIpForwarding: false
    configureOsForwarding: false
    testPortRangeStart: testPortRangeStart
    testPortRangeEnd: testPortRangeEnd
  }
}

module vm2 'modules/linux-vm.bicep' = {
  name: 'vm2'
  params: {
    location: location
    vmName: '${namePrefix}-vm2'
    subnetId: network.outputs.endpointBSubnetId
    adminUsername: adminUsername
    adminPublicKey: adminPublicKey
    vmSize: endpointVmSize
    enableAcceleratedNetworking: enableEndpointAcceleratedNetworking
    enableIpForwarding: false
    configureOsForwarding: false
    testPortRangeStart: testPortRangeStart
    testPortRangeEnd: testPortRangeEnd
  }
}

module router 'modules/linux-vm.bicep' = {
  name: 'router'
  params: {
    location: location
    vmName: routerVmName
    subnetId: network.outputs.routerSubnetId
    adminUsername: adminUsername
    adminPublicKey: adminPublicKey
    vmSize: routerVmSize
    osDiskStorageAccountType: routerOsDiskStorageAccountType
    enableAcceleratedNetworking: true
    enableIpForwarding: true
    privateIpAddress: routerPrivateIpAddress
    configureOsForwarding: true
    testPortRangeStart: testPortRangeStart
    testPortRangeEnd: testPortRangeEnd
  }
}

output routerOperatingSystem string = 'AzureLinux'
output routerVmName string = routerVmName
output routerPrivateIp string = routerPrivateIpAddress
output routerPublicIp string = router.outputs.publicIpAddress
output vm1Name string = '${namePrefix}-vm1'
output vm2Name string = '${namePrefix}-vm2'
output vm1PrivateIp string = vm1.outputs.privateIpAddress
output vm1PublicIp string = vm1.outputs.publicIpAddress
output vm2PrivateIp string = vm2.outputs.privateIpAddress
output vm2PublicIp string = vm2.outputs.publicIpAddress

// Compatibility aliases for scripts consuming deployments created by earlier versions.
output endpointAVmName string = '${namePrefix}-vm1'
output endpointBVmName string = '${namePrefix}-vm2'
output endpointAPrivateIp string = vm1.outputs.privateIpAddress
output endpointAPublicIp string = vm1.outputs.publicIpAddress
output endpointBPrivateIp string = vm2.outputs.privateIpAddress
output endpointBPublicIp string = vm2.outputs.publicIpAddress
output testPortRange string = '${testPortRangeStart}-${testPortRangeEnd}'
