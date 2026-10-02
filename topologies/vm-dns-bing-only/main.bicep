targetScope = 'resourceGroup'

@description('Region supporting Azure DNS Private Resolver, resolver policies, and the VM image.')
param location string = resourceGroup().location

@description('Prefix for the topology resources.')
@minLength(1)
@maxLength(50)
param vmName string = 'vm-dns-bing-only'

param vnetAddressPrefix string = '10.50.0.0/16'
param vmSubnetAddressPrefix string = '10.50.0.0/24'

@description('Dedicated resolver subnet, between /28 and /24.')
param resolverSubnetAddressPrefix string = '10.50.1.0/28'

@description('Usable static address in the resolver subnet; do not use its first four or last address.')
param resolverIpAddress string = '10.50.1.4'

param adminUsername string = 'azureuser'

@secure()
param adminPublicKey string

param vmSize string = 'Standard_D4d_v5'
param imageVersion string = 'latest'

var sshRules = [
  for (source, index) in ['CorpnetPublic', 'CorpnetSAW']: {
    name: 'AllowSsh${source}'
    properties: {
      access: 'Allow'
      direction: 'Inbound'
      priority: 100 + index * 10
      protocol: 'Tcp'
      sourceAddressPrefix: source
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '22'
    }
  }
]

var dnsRules = [
  for (rule, index) in [
    { name: 'AllowResolverDns', destination: resolverIpAddress, access: 'Allow' }
    { name: 'AllowAzureDns', destination: 'AzurePlatformDNS', access: 'Allow' }
    { name: 'DenyOtherDns', destination: '*', access: 'Deny' }
  ]: {
    name: rule.name
    properties: {
      access: rule.access
      direction: 'Outbound'
      priority: 100 + index * 10
      protocol: '*'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: rule.destination
      destinationPortRange: '53'
    }
  }
]

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${vmName}-nsg'
  location: location
  properties: {
    securityRules: concat(sshRules, dnsRules, [
      {
        name: 'DenyAllOtherInbound'
        properties: {
          access: 'Deny'
          direction: 'Inbound'
          priority: 4096
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ])
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: '${vmName}-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [vnetAddressPrefix]
    }
    subnets: [
      {
        name: 'vm'
        properties: {
          addressPrefix: vmSubnetAddressPrefix
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
      {
        name: 'resolver-inbound'
        properties: {
          addressPrefix: resolverSubnetAddressPrefix
          delegations: [
            {
              name: 'dnsResolver'
              properties: {
                serviceName: 'Microsoft.Network/dnsResolvers'
              }
            }
          ]
        }
      }
    ]
  }
}

resource resolver 'Microsoft.Network/dnsResolvers@2025-05-01' = {
  name: '${vmName}-resolver'
  location: location
  properties: {
    virtualNetwork: {
      id: vnet.id
    }
  }
}

resource inbound 'Microsoft.Network/dnsResolvers/inboundEndpoints@2025-05-01' = {
  parent: resolver
  name: 'inbound'
  location: location
  properties: {
    ipConfigurations: [
      {
        privateIpAllocationMethod: 'Static'
        privateIpAddress: resolverIpAddress
        subnet: {
          id: vnet.properties.subnets[1].id
        }
      }
    ]
  }
}

resource policy 'Microsoft.Network/dnsResolverPolicies@2025-05-01' = {
  name: '${vmName}-policy'
  location: location
  properties: {}
}

resource allowedDomains 'Microsoft.Network/dnsResolverDomainLists@2025-05-01' = {
  name: '${vmName}-allow-bing'
  location: location
  properties: {
    domains: ['www.bing.com']
  }
}

resource allDomains 'Microsoft.Network/dnsResolverDomainLists@2025-05-01' = {
  name: '${vmName}-all-domains'
  location: location
  properties: {
    domains: ['.']
  }
}

resource allowBing 'Microsoft.Network/dnsResolverPolicies/dnsSecurityRules@2025-05-01' = {
  parent: policy
  name: 'allow-www-bing-com'
  location: location
  properties: {
    priority: 100
    dnsSecurityRuleState: 'Enabled'
    action: {
      actionType: 'Allow'
    }
    dnsResolverDomainLists: [{ id: allowedDomains.id }]
  }
}

resource blockOthers 'Microsoft.Network/dnsResolverPolicies/dnsSecurityRules@2025-05-01' = {
  parent: policy
  name: 'block-all-other-domains'
  location: location
  properties: {
    priority: 200
    dnsSecurityRuleState: 'Enabled'
    action: {
      actionType: 'Block'
    }
    dnsResolverDomainLists: [{ id: allDomains.id }]
  }
}

resource policyLink 'Microsoft.Network/dnsResolverPolicies/virtualNetworkLinks@2025-05-01' = {
  parent: policy
  name: 'topology-vnet'
  location: location
  properties: {
    virtualNetwork: {
      id: vnet.id
    }
  }
  dependsOn: [allowBing, blockOthers]
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: '${vmName}-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${vmName}-nic'
  location: location
  properties: {
    enableAcceleratedNetworking: true
    dnsSettings: {
      dnsServers: [inbound.properties.ipConfigurations[0].privateIpAddress]
    }
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: vnet.properties.subnets[0].id
          }
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
  }
  dependsOn: [policyLink]
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    networkProfile: {
      networkInterfaces: [{ id: nic.id }]
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        provisionVMAgent: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      diskControllerType: 'SCSI'
      imageReference: {
        publisher: 'MicrosoftAzureLinux'
        offer: 'azurelinux-4'
        sku: '4'
        version: imageVersion
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

output vmId string = vm.id
output vnetId string = vnet.id
output resolverId string = resolver.id
output resolverPolicyId string = policy.id
output resolverIpAddress string = inbound.properties.ipConfigurations[0].privateIpAddress
output publicIpAddress string = publicIp.properties.ipAddress
output sshCommand string = 'ssh ${adminUsername}@${publicIp.properties.ipAddress}'
