targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Prefix applied to every resource name.')
param namePrefix string = 'fwd'

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

@description('Guest operating system used by the forwarding VM.')
@allowed([
  'AzureLinux'
  'WindowsServer2022'
])
param routerOs string = 'AzureLinux'

@description('Administrator user name for every VM.')
param adminUsername string = 'azureuser'

@description('SSH public key used by the Linux VMs.')
@secure()
param adminPublicKey string

@description('Administrator password for the Windows router VM. Required only when routerOs is WindowsServer2022.')
@secure()
param routerAdminPassword string = ''

@description('Size of the two endpoint VMs.')
param endpointVmSize string = 'Standard_D2s_v5'

@description('Size of the router VM. Must support Accelerated Networking.')
param routerVmSize string = 'Standard_D4s_v5'

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

var deployWindowsRouter = routerOs == 'WindowsServer2022'
var routerVmName = deployWindowsRouter ? '${namePrefix}-router-win' : '${namePrefix}-router-lnx'

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

module endpointA 'modules/linux-vm.bicep' = {
  name: 'endpoint-a'
  params: {
    location: location
    vmName: '${namePrefix}-endpoint-a'
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

module endpointB 'modules/linux-vm.bicep' = {
  name: 'endpoint-b'
  params: {
    location: location
    vmName: '${namePrefix}-endpoint-b'
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

module linuxRouter 'modules/linux-vm.bicep' = if (!deployWindowsRouter) {
  name: 'router-linux'
  params: {
    location: location
    vmName: routerVmName
    subnetId: network.outputs.routerSubnetId
    adminUsername: adminUsername
    adminPublicKey: adminPublicKey
    vmSize: routerVmSize
    enableAcceleratedNetworking: true
    enableIpForwarding: true
    privateIpAddress: routerPrivateIpAddress
    configureOsForwarding: true
    testPortRangeStart: testPortRangeStart
    testPortRangeEnd: testPortRangeEnd
  }
}

module windowsRouter 'modules/windows-router-vm.bicep' = if (deployWindowsRouter) {
  name: 'router-windows'
  params: {
    location: location
    vmName: routerVmName
    subnetId: network.outputs.routerSubnetId
    adminUsername: adminUsername
    adminPassword: routerAdminPassword
    vmSize: routerVmSize
    enableAcceleratedNetworking: true
    privateIpAddress: routerPrivateIpAddress
    testPortRangeStart: testPortRangeStart
    testPortRangeEnd: testPortRangeEnd
  }
}

output routerOperatingSystem string = routerOs
output routerVmName string = routerVmName
output routerPrivateIp string = routerPrivateIpAddress
output routerPublicIp string = deployWindowsRouter ? windowsRouter!.outputs.publicIpAddress : linuxRouter!.outputs.publicIpAddress
output endpointAVmName string = '${namePrefix}-endpoint-a'
output endpointBVmName string = '${namePrefix}-endpoint-b'
output endpointAPrivateIp string = endpointA.outputs.privateIpAddress
output endpointAPublicIp string = endpointA.outputs.publicIpAddress
output endpointBPrivateIp string = endpointB.outputs.privateIpAddress
output endpointBPublicIp string = endpointB.outputs.publicIpAddress
output testPortRange string = '${testPortRangeStart}-${testPortRangeEnd}'
