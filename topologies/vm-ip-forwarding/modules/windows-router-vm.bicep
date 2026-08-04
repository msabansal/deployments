@description('Azure region for all resources.')
param location string

@description('Name of the virtual machine.')
param vmName string

@description('Resource ID of the subnet the VM is placed in.')
param subnetId string

@description('Administrator user name.')
param adminUsername string

@description('Administrator password.')
@secure()
param adminPassword string

@description('Virtual machine size.')
param vmSize string

@description('Storage account type for the OS disk. An empty string leaves the property off the VM, which is what a redeploy over an already-resized VM needs.')
param osDiskStorageAccountType string = 'Premium_LRS'

@description('Disk controller the VM boots from. NVMe keeps every size this topology uses on the same controller, so a resize never has to change it.')
param diskControllerType string = 'NVMe'

@description('Enable Accelerated Networking on the network interface.')
param enableAcceleratedNetworking bool

@description('Static private IP to assign. User-defined routes point at this address.')
param privateIpAddress string

@description('First port of the test traffic range opened in the guest firewall.')
param testPortRangeStart int

@description('Last port of the test traffic range opened in the guest firewall.')
param testPortRangeEnd int

var rawScript = '''
$ErrorActionPreference = 'Stop'
$portRange = '__PORT_START__-__PORT_END__'

# Persistent global IPv4 forwarding. Set-NetIPInterface below is what actually enables
# forwarding for this boot; this registry value keeps it enabled across a restart.
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' `
  -Name 'IPEnableRouter' -Value 1 -Type DWord

# Per-interface forwarding, which takes effect immediately and without a restart.
#
# The RemoteAccess and Routing roles are deliberately not installed. RRAS is only required
# for NAT, demand-dial, VPN, or dynamic routing protocols. Static forwarding between subnets
# is performed by the TCP/IP stack itself, so installing RRAS would add several minutes and
# a reboot to the deployment without changing the datapath.
#
# Accelerated Networking exposes two "physical" adapters: the synthetic NetVSC NIC and the
# Mellanox virtual function bound underneath it. The VF has no IPv4 stack of its own, so
# addressing it by adapter index throws "No matching MSFT_NetIPInterface objects found".
# Enumerating the IPv4 interfaces directly only ever returns interfaces that can be set.
$ipv4Interfaces = Get-NetIPInterface -AddressFamily IPv4 |
  Where-Object { $_.ConnectionState -eq 'Connected' -and $_.InterfaceAlias -notlike 'Loopback*' }

if (-not $ipv4Interfaces) {
  throw 'No connected IPv4 interfaces were found on the router VM.'
}

foreach ($ipv4Interface in $ipv4Interfaces) {
  try {
    Set-NetIPInterface -InputObject $ipv4Interface -Forwarding Enabled
    Write-Output "Forwarding enabled on $($ipv4Interface.InterfaceAlias) (ifIndex $($ipv4Interface.InterfaceIndex))"
  }
  catch {
    Write-Output "Could not enable forwarding on $($ipv4Interface.InterfaceAlias): $($_.Exception.Message)"
  }
}

function Set-TopologyFirewallRule {
  param($Name, $Params)
  Remove-NetFirewallRule -DisplayName $Name -ErrorAction SilentlyContinue
  New-NetFirewallRule @Params -DisplayName $Name -Direction Inbound -Action Allow -Profile Any | Out-Null
}

Set-TopologyFirewallRule -Name 'Topology test traffic (TCP)' -Params @{ Protocol = 'TCP'; LocalPort = $portRange }
Set-TopologyFirewallRule -Name 'Topology test traffic (UDP)' -Params @{ Protocol = 'UDP'; LocalPort = $portRange }
Set-TopologyFirewallRule -Name 'Topology ICMPv4 echo' -Params @{ Protocol = 'ICMPv4'; IcmpType = 8 }

# Fail loudly rather than leaving a router that silently drops transit traffic.
$router = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name 'IPEnableRouter').IPEnableRouter
$forwardingState = Get-NetIPInterface -AddressFamily IPv4 |
  Where-Object { $_.ConnectionState -eq 'Connected' -and $_.InterfaceAlias -notlike 'Loopback*' } |
  Select-Object InterfaceAlias, InterfaceIndex, Forwarding

Write-Output "IPEnableRouter=$router"
$forwardingState | Format-Table -AutoSize | Out-String | Write-Output

if (-not ($forwardingState | Where-Object Forwarding -eq 'Enabled')) {
  throw 'IPv4 forwarding is not enabled on any connected interface of the router VM.'
}

Write-Output 'configuration complete'
'''

var script = replace(
  replace(rawScript, '__PORT_START__', string(testPortRangeStart)),
  '__PORT_END__',
  string(testPortRangeEnd)
)

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

resource networkInterface 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${vmName}-nic'
  location: location
  properties: {
    enableAcceleratedNetworking: enableAcceleratedNetworking
    enableIPForwarding: true
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: privateIpAddress
          publicIPAddress: {
            id: publicIp.id
          }
          subnet: {
            id: subnetId
          }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: networkInterface.id
          properties: {
            primary: true
          }
        }
      ]
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
      }
    }
    storageProfile: {
      diskControllerType: diskControllerType
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-azure-edition'
        version: 'latest'
      }
      osDisk: union({
        createOption: 'FromImage'
      }, empty(osDiskStorageAccountType) ? {} : {
        managedDisk: {
          storageAccountType: osDiskStorageAccountType
        }
      })
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

resource configure 'Microsoft.Compute/virtualMachines/runCommands@2024-07-01' = {
  name: 'configure-topology'
  parent: vm
  location: location
  properties: {
    treatFailureAsDeploymentFailure: true
    source: {
      script: script
    }
  }
}

output vmId string = vm.id
output privateIpAddress string = networkInterface.properties.ipConfigurations[0].properties.privateIPAddress
output publicIpAddress string = publicIp.properties.ipAddress
