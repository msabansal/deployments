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

# Persistent global IPv4 forwarding.
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' `
  -Name 'IPEnableRouter' -Value 1 -Type DWord

# Per-interface forwarding, which takes effect without a restart.
Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | ForEach-Object {
  Set-NetIPInterface -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -Forwarding Enabled
}

$installResult = $null

try {
  $installResult = Install-WindowsFeature -Name RemoteAccess, Routing -IncludeManagementTools
  if (-not (Get-RemoteAccess -ErrorAction SilentlyContinue)) {
    Install-RemoteAccess -VpnType RoutingOnly -Force
  }
  Set-Service -Name RemoteAccess -StartupType Automatic
  Restart-Service -Name RemoteAccess -Force
}
catch {
  Write-Output "RemoteAccess routing configuration deferred: $($_.Exception.Message)"
}

function Set-TopologyFirewallRule {
  param($Name, $Params)
  Remove-NetFirewallRule -DisplayName $Name -ErrorAction SilentlyContinue
  New-NetFirewallRule @Params -DisplayName $Name -Direction Inbound -Action Allow -Profile Any | Out-Null
}

Set-TopologyFirewallRule -Name 'Topology test traffic (TCP)' -Params @{ Protocol = 'TCP'; LocalPort = $portRange }
Set-TopologyFirewallRule -Name 'Topology test traffic (UDP)' -Params @{ Protocol = 'UDP'; LocalPort = $portRange }
Set-TopologyFirewallRule -Name 'Topology ICMPv4 echo' -Params @{ Protocol = 'ICMPv4'; IcmpType = 8 }

if ($installResult -and $installResult.RestartNeeded -eq 'Yes') {
  Write-Output 'Restart required by RemoteAccess installation; restarting in 120 seconds.'
  & shutdown.exe /r /t 120 /c 'Completing router role installation'
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
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-azure-edition'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
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
