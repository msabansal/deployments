[CmdletBinding()]
param(
  [string] $ResourceGroupName = 'sabansal-ilb-routing-rg',

  [string] $DeploymentName = 'sabansal-ecmp-routing',

  [string] $AdminUsername = 'azureuser',

  [string] $SshPrivateKeyPath = '~\.ssh\id_ed25519',

  [ValidateRange(1, 100000)]
  [int] $UdpTargetMbps = 5000,

  [ValidateRange(2, 32)]
  [int] $ParallelStreams = 16,

  [ValidateRange(64, 65507)]
  [int] $UdpDatagramBytes = 1350,

  [ValidateRange(5, 600)]
  [int] $DurationSeconds = 30
)

$ErrorActionPreference = 'Stop'

$resolvedPrivateKeyPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SshPrivateKeyPath)
if (-not (Test-Path -LiteralPath $resolvedPrivateKeyPath -PathType Leaf)) {
  throw "SSH private key file was not found: $resolvedPrivateKeyPath"
}

$sshOptions = @(
  '-i', $resolvedPrivateKeyPath,
  '-o', 'BatchMode=yes',
  '-o', 'StrictHostKeyChecking=accept-new',
  '-o', 'ConnectTimeout=15',
  '-o', 'ServerAliveInterval=15',
  '-o', 'ServerAliveCountMax=4'
)

function Invoke-SshCommand {
  param(
    [Parameter(Mandatory)] [string] $HostName,
    [Parameter(Mandatory)] [string] $Command
  )

  $output = & ssh @sshOptions "$AdminUsername@$HostName" $Command
  if ($LASTEXITCODE -ne 0) {
    throw "SSH command failed on '$HostName' with exit code $LASTEXITCODE."
  }
  return ($output -join "`n").Trim()
}

function Invoke-SshScript {
  param(
    [Parameter(Mandatory)] [string] $HostName,
    [Parameter(Mandatory)] [string] $Script
  )

  $normalizedScript = $Script -replace "`r`n", "`n"
  $encodedScript = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($normalizedScript))
  return Invoke-SshCommand -HostName $HostName -Command "echo '$encodedScript' | base64 -d | bash"
}

function Get-ForwardedDatagrams {
  param([Parameter(Mandatory)] [string] $HostName)

  $value = Invoke-SshScript -HostName $HostName -Script @'
set -euo pipefail
awk '$1 == "Ip:" {
  if (++line == 1) {
    for (i = 1; i <= NF; i++) if ($i == "ForwDatagrams") column = i
  } else if (column) {
    print $column
  }
}' /proc/net/snmp
'@

  [long] $counter = 0
  if (-not [long]::TryParse($value.Trim(), [ref] $counter)) {
    throw "Could not parse ForwDatagrams from '$HostName': $value"
  }
  return $counter
}

function Assert-EcmpRoute {
  param(
    [Parameter(Mandatory)] [string] $RouteTableName,
    [Parameter(Mandatory)] [string] $RouteName,
    [Parameter(Mandatory)] [string] $DestinationPrefix,
    [Parameter(Mandatory)] [string[]] $ExpectedNextHopIps
  )

  $subscriptionId = az account show --query id --output tsv
  if ($LASTEXITCODE -ne 0 -or -not $subscriptionId) {
    throw 'Could not determine the active Azure subscription.'
  }

  $routeUrl = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Network/routeTables/$RouteTableName/routes/$RouteName`?api-version=2025-09-01"
  $routeJson = az rest --method get --url $routeUrl --output json
  if ($LASTEXITCODE -ne 0 -or -not $routeJson) {
    throw "Could not read route '$RouteName' from route table '$RouteTableName'."
  }

  $route = $routeJson | ConvertFrom-Json
  $actualNextHops = @($route.properties.nextHop.nextHopIpAddresses | Sort-Object)
  $expectedNextHops = @($ExpectedNextHopIps | Sort-Object)
  if ($route.properties.addressPrefix -ne $DestinationPrefix `
      -or $route.properties.nextHopType -ne 'VirtualApplianceEcmp' `
      -or ($actualNextHops -join ',') -ne ($expectedNextHops -join ',')) {
    throw "Route '$RouteName' is not ECMP $DestinationPrefix via [$($expectedNextHops -join ', ')]."
  }
}

function Assert-EffectiveEcmpRoute {
  param(
    [Parameter(Mandatory)] [string] $NicName,
    [Parameter(Mandatory)] [string] $DestinationPrefix,
    [Parameter(Mandatory)] [string[]] $ExpectedNextHopIps
  )

  $routesJson = az network nic show-effective-route-table `
    --resource-group $ResourceGroupName `
    --name $NicName `
    --output json

  if ($LASTEXITCODE -ne 0 -or -not $routesJson) {
    throw "Could not read the effective route table for '$NicName'."
  }

  $routes = $routesJson | ConvertFrom-Json
  $route = $routes.value | Where-Object {
    @($_.addressPrefix) -contains $DestinationPrefix -and $_.state -eq 'Active'
  } | Select-Object -First 1

  if (-not $route) {
    throw "No active effective route for '$DestinationPrefix' was found on '$NicName'."
  }

  $actualNextHops = @($route.nextHopIpAddress | Sort-Object)
  $expectedNextHops = @($ExpectedNextHopIps | Sort-Object)
  if ($route.nextHopType -notin @('VirtualApplianceEcmp', 'VirtualAppliance') `
      -or ($actualNextHops -join ',') -ne ($expectedNextHops -join ',')) {
    throw "Effective route '$DestinationPrefix' on '$NicName' uses $($route.nextHopType) [$($actualNextHops -join ', ')] instead of ECMP [$($expectedNextHops -join ', ')]."
  }
}

$outputsJson = az deployment group show `
  --resource-group $ResourceGroupName `
  --name $DeploymentName `
  --query properties.outputs `
  --output json

if ($LASTEXITCODE -ne 0 -or -not $outputsJson) {
  throw "Could not read outputs from deployment '$DeploymentName'."
}

$outputs = $outputsJson | ConvertFrom-Json
$vm1Name = $outputs.vm1Name.value
$vm1NicName = $outputs.vm1NicName.value
$vm1PublicIp = $outputs.vm1PublicIp.value
$vm1SubnetPrefix = $outputs.vm1SubnetPrefix.value
$vm2Name = $outputs.vm2Name.value
$vm2NicName = $outputs.vm2NicName.value
$vm2Ip = $outputs.vm2PrivateIp.value
$vm2PublicIp = $outputs.vm2PublicIp.value
$vm2SubnetPrefix = $outputs.vm2SubnetPrefix.value
$router1Name = $outputs.router1Name.value
$router1PublicIp = $outputs.router1PublicIp.value
$router2Name = $outputs.router2Name.value
$router2PublicIp = $outputs.router2PublicIp.value
$ecmpNextHopIps = @($outputs.ecmpNextHopIps.value)

Write-Host 'Validating configured and effective ECMP routes...'

Assert-EcmpRoute `
  -RouteTableName $outputs.vm1RouteTableName.value `
  -RouteName $outputs.vm1RouteName.value `
  -DestinationPrefix $vm2SubnetPrefix `
  -ExpectedNextHopIps $ecmpNextHopIps
Assert-EcmpRoute `
  -RouteTableName $outputs.vm2RouteTableName.value `
  -RouteName $outputs.vm2RouteName.value `
  -DestinationPrefix $vm1SubnetPrefix `
  -ExpectedNextHopIps $ecmpNextHopIps
Assert-EffectiveEcmpRoute `
  -NicName $vm1NicName `
  -DestinationPrefix $vm2SubnetPrefix `
  -ExpectedNextHopIps $ecmpNextHopIps
Assert-EffectiveEcmpRoute `
  -NicName $vm2NicName `
  -DestinationPrefix $vm1SubnetPrefix `
  -ExpectedNextHopIps $ecmpNextHopIps

Write-Host "  VM1 route: $vm2SubnetPrefix via ECMP [$($ecmpNextHopIps -join ', ')]" -ForegroundColor Green
Write-Host "  VM2 route: $vm1SubnetPrefix via ECMP [$($ecmpNextHopIps -join ', ')]" -ForegroundColor Green

$serverResult = Invoke-SshScript -HostName $vm2PublicIp -Script @'
set -euo pipefail
IPERF=/usr/local/bin/iperf3
"$IPERF" --help 2>&1 | grep -q -- '--gsro'
pkill -f 'iperf3 -s' 2>/dev/null || true
"$IPERF" -s --daemon --port 5201
sleep 2
pgrep -f 'iperf3 -s' >/dev/null
echo IPERF_SERVER_STARTED
'@

if ($serverResult -notmatch 'IPERF_SERVER_STARTED') {
  throw "Could not start iperf3 on '$vm2Name': $serverResult"
}

try {
  $router1Before = Get-ForwardedDatagrams -HostName $router1PublicIp
  $router2Before = Get-ForwardedDatagrams -HostName $router2PublicIp

  $streamRateMbps = [math]::Ceiling($UdpTargetMbps / $ParallelStreams)
  $effectiveTargetMbps = $streamRateMbps * $ParallelStreams

  $clientScript = @'
set -euo pipefail
TARGET=__TARGET_IP__
REPORT=/tmp/ecmp-routing-udp.json
IPERF=/usr/local/bin/iperf3
"$IPERF" --help 2>&1 | grep -q -- '--gsro'
ping -c 3 -W 3 "$TARGET" >/dev/null

read -r _ cpu_user cpu_nice cpu_system cpu_idle cpu_iowait cpu_irq cpu_softirq cpu_steal _ </proc/stat
CPU_TOTAL_BEFORE=$((cpu_user + cpu_nice + cpu_system + cpu_idle + cpu_iowait + cpu_irq + cpu_softirq + cpu_steal))
CPU_IDLE_BEFORE=$((cpu_idle + cpu_iowait))

"$IPERF" -c "$TARGET" -p 5201 -u -P __STREAMS__ -b __STREAM_RATE__M \
  -l __DATAGRAM_BYTES__ -t __DURATION__ --gsro --json >"$REPORT"

read -r _ cpu_user cpu_nice cpu_system cpu_idle cpu_iowait cpu_irq cpu_softirq cpu_steal _ </proc/stat
CPU_TOTAL_AFTER=$((cpu_user + cpu_nice + cpu_system + cpu_idle + cpu_iowait + cpu_irq + cpu_softirq + cpu_steal))
CPU_IDLE_AFTER=$((cpu_idle + cpu_iowait))

python3 - "$REPORT" "$CPU_TOTAL_BEFORE" "$CPU_IDLE_BEFORE" "$CPU_TOTAL_AFTER" "$CPU_IDLE_AFTER" <<'PYEOF'
import json
import sys

with open(sys.argv[1]) as handle:
    report = json.load(handle)

if report.get("error"):
    raise RuntimeError(report["error"])

udp_end = report["end"]
sent = udp_end.get("sum_sent") or udp_end["sum"]
received = udp_end.get("sum_received") or udp_end["sum"]
total_delta = int(sys.argv[4]) - int(sys.argv[2])
idle_delta = int(sys.argv[5]) - int(sys.argv[3])

print(json.dumps({
    "seconds": received["seconds"],
    "bits_per_second_sent": sent["bits_per_second"],
    "bits_per_second_received": received["bits_per_second"],
    "jitter_ms": received.get("jitter_ms", 0),
    "lost_packets": received.get("lost_packets", 0),
    "packets": received.get("packets", 0),
    "lost_percent": received.get("lost_percent", 0),
    "client_vm_cpu_percent": 100.0 * (total_delta - idle_delta) / total_delta,
}, separators=(",", ":")))
PYEOF
'@ -replace '__TARGET_IP__', $vm2Ip `
     -replace '__STREAMS__', $ParallelStreams `
     -replace '__STREAM_RATE__', $streamRateMbps `
     -replace '__DATAGRAM_BYTES__', $UdpDatagramBytes `
     -replace '__DURATION__', $DurationSeconds

  $clientResult = Invoke-SshScript -HostName $vm1PublicIp -Script $clientScript
  try {
    $result = $clientResult | ConvertFrom-Json
  }
  catch {
    throw "Could not parse UDP result from '$vm1Name': $clientResult"
  }

  $router1Delta = (Get-ForwardedDatagrams -HostName $router1PublicIp) - $router1Before
  $router2Delta = (Get-ForwardedDatagrams -HostName $router2PublicIp) - $router2Before

  if ($router1Delta -le 0 -or $router2Delta -le 0) {
    throw "ECMP did not send benchmark traffic through both routers. Router 1: $router1Delta; router 2: $router2Delta."
  }

  Write-Host ''
  Write-Host '===================== ECMP-routed UDP throughput =====================' -ForegroundColor Cyan
  Write-Host "  path               : $vm1Name -> [$($ecmpNextHopIps -join ', ')] -> $vm2Name"
  Write-Host "  offered rate       : $effectiveTargetMbps Mbits/sec"
  Write-Host "  streams            : $ParallelStreams"
  Write-Host "  datagram           : $UdpDatagramBytes bytes"
  Write-Host ("  duration           : {0:N1} seconds" -f $result.seconds)
  Write-Host ("  sent               : {0:N2} Gbits/sec" -f ($result.bits_per_second_sent / 1e9))
  Write-Host ("  received           : {0:N2} Gbits/sec" -f ($result.bits_per_second_received / 1e9)) -ForegroundColor Green
  Write-Host ("  packet loss        : {0:N2}% ({1:N0}/{2:N0})" -f $result.lost_percent, $result.lost_packets, $result.packets)
  Write-Host ("  jitter             : {0:N3} ms" -f $result.jitter_ms)
  Write-Host ("  VM1 CPU            : {0:N1}%" -f $result.client_vm_cpu_percent)
  Write-Host ("  router-1 forwarded : {0:N0} datagrams" -f $router1Delta)
  Write-Host ("  router-2 forwarded : {0:N0} datagrams" -f $router2Delta)
  Write-Host '======================================================================' -ForegroundColor Cyan
}
finally {
  try {
    Invoke-SshCommand -HostName $vm2PublicIp -Command "pkill -x iperf3 2>/dev/null || true; echo IPERF_SERVER_STOPPED" | Out-Null
  }
  catch {
    Write-Warning "Could not stop iperf3 on '$vm2Name': $($_.Exception.Message)"
  }
}
