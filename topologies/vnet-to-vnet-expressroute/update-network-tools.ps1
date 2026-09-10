<#
.SYNOPSIS
Installs connectivity tools on only the two expected ER topology VMs, without redeployment.
.EXAMPLE
.\update-network-tools.ps1 -ResourceGroupName sabansal-ertest1 -SubscriptionId <subscription-id>
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ResourceGroupName,
  [string] $SubscriptionId,
  [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9-]*$')] [string] $NamePrefix = 'vnet-to-vnet-er'
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\scripts\NetworkTools.Common.ps1"
$vms = @(Get-ErTestVms -ResourceGroupName $ResourceGroupName -NamePrefix $NamePrefix -SubscriptionId $SubscriptionId)
$installer = Get-Content -LiteralPath "$PSScriptRoot\scripts\install-network-tools.sh" -Raw
for ($i = 0; $i -lt 2; $i++) {
  $vm = $vms[$i]
  $peer = $vms[1 - $i]
  Write-Host "Installing network tools on $($vm.Name) ($($vm.PrivateIp)); peer $($peer.PrivateIp)..."
  $result = Invoke-ErVmScript -ResourceGroupName $ResourceGroupName -SubscriptionId $SubscriptionId `
    -VmName $vm.Name -Script $installer.Replace('__PEER_SOURCE__', "$($peer.PrivateIp)/32") -TimeoutSeconds 900
  Write-Host $result.Stdout
}
