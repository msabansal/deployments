<#
.SYNOPSIS
Tests ping in both directions and TCP iperf3 between the ER topology's private NIC IPs.
.DESCRIPTION
Default throughput direction is on-premises to Azure. Reverse measures Azure to on-premises.
End-to-end connectivity and throughput do not prove ExpressRoute or FastPath traversal.
.EXAMPLE
.\test-connectivity.ps1 -ResourceGroupName sabansal-ertest1 -SubscriptionId <subscription-id>
.EXAMPLE
.\test-connectivity.ps1 -ResourceGroupName sabansal-ertest1 -SubscriptionId <subscription-id> -Reverse
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ResourceGroupName,
  [string] $SubscriptionId,
  [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9-]*$')] [string] $NamePrefix = 'vnet-to-vnet-er',
  [ValidateRange(5, 120)] [int] $DurationSeconds = 15,
  [ValidateRange(1, 32)] [int] $ParallelConnections = 4,
  [ValidateRange(5201, 5210)] [int] $Port = 5201,
  [switch] $Reverse,
  [switch] $PassThru
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\scripts\NetworkTools.Common.ps1"
$vms = @(Get-ErTestVms -ResourceGroupName $ResourceGroupName -NamePrefix $NamePrefix -SubscriptionId $SubscriptionId)
$client = $vms[0]
$server = $vms[1]
$unit = "er-iperf-$([guid]::NewGuid().ToString('N')).service"
$direction = if ($Reverse) { '--reverse' } else { '' }
$scripts = @{}
foreach ($name in @('start-connectivity-server', 'run-connectivity-client', 'stop-connectivity-server')) {
  $text = Get-Content -LiteralPath "$PSScriptRoot\scripts\$name.sh" -Raw
  $scripts[$name] = $text.Replace('__UNIT__', $unit).
    Replace('__PORT__', "$Port").Replace('__CLIENT_IP__', $client.PrivateIp).
    Replace('__SERVER_IP__', $server.PrivateIp).Replace('__STREAMS__', "$ParallelConnections").
    Replace('__DURATION__', "$DurationSeconds").Replace('__DIRECTION__', $direction).
    Replace('__CLIENT_TIMEOUT__', "$($DurationSeconds + 30)").
    Replace('__LIFETIME__', "$($DurationSeconds + 300)")
}
$invokeParams = @{ ResourceGroupName = $ResourceGroupName; SubscriptionId = $SubscriptionId }
$failure = $null
$result = $null
try {
  Write-Host "Testing $($client.Name) ($($client.PrivateIp)) <-> $($server.Name) ($($server.PrivateIp))..."
  $started = Invoke-ErVmScript @invokeParams -VmName $server.Name `
    -Script $scripts['start-connectivity-server'] -TimeoutSeconds 60
  $serverPing = $started.Stdout | ConvertFrom-Json
  $tested = Invoke-ErVmScript @invokeParams -VmName $client.Name `
    -Script $scripts['run-connectivity-client'] -TimeoutSeconds ($DurationSeconds + 65)
  $report = $tested.Stdout | ConvertFrom-Json
  $result = [pscustomobject]@{
    ResourceGroupName = $ResourceGroupName
    ClientVmName = $client.Name
    ServerVmName = $server.Name
    ClientPrivateIp = $client.PrivateIp
    ServerPrivateIp = $server.PrivateIp
    Direction = $(if ($Reverse) { 'Azure -> on-premises' } else { 'On-premises -> Azure' })
    Port = $Port
    ParallelConnections = $ParallelConnections
    DurationSeconds = $report.seconds
    BytesSent = $report.bytes_sent
    BitsPerSecondSent = $report.bits_per_second_sent
    BitsPerSecondReceived = $report.bits_per_second_received
    Retransmits = $report.retransmits
    OnPremToAzurePingLossPercent = $report.ping_loss_percent
    OnPremToAzurePingAverageMs = $report.ping_average_ms
    AzureToOnPremPingLossPercent = $serverPing.ping_loss_percent
    AzureToOnPremPingAverageMs = $serverPing.ping_average_ms
    TimestampUtc = [DateTime]::UtcNow
  }
}
catch {
  $failure = $_
  throw
}
finally {
  # Also clean up when startup fails after creating the unit. Its independent
  # RuntimeMaxSec deadline bounds its lifetime if this local process is aborted.
  try {
    Invoke-ErVmScript @invokeParams -VmName $server.Name `
      -Script $scripts['stop-connectivity-server'] -TimeoutSeconds 30 | Out-Null
  }
  catch {
    if ($failure) { Write-Warning "Server cleanup also failed; original test failure retained: $_" }
    else { throw }
  }
}

Write-Host ("Ping on-premises -> Azure: {0}% loss, {1:N2} ms; Azure -> on-premises: {2}% loss, {3:N2} ms" -f
  $result.OnPremToAzurePingLossPercent, $result.OnPremToAzurePingAverageMs,
  $result.AzureToOnPremPingLossPercent, $result.AzureToOnPremPingAverageMs)
Write-Host ("TCP {0}: sent {1:N3} Gbit/s, received {2:N3} Gbit/s; retransmits {3}; {4} streams, {5:N1}s, port {6}" -f
  $result.Direction, ($result.BitsPerSecondSent / 1e9), ($result.BitsPerSecondReceived / 1e9),
  $result.Retransmits, $ParallelConnections, $result.DurationSeconds, $Port)
Write-Host 'End-to-end results are not proof of ExpressRoute or FastPath traversal.'
if ($PassThru) { $result }
