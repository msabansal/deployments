[CmdletBinding()]
param(
  [string] $ResourceGroupName = 'sabansal-ilb-routing-two-infra-rg',

  [string] $DeploymentName = 'sabansal-ilb-routing-two-infra',

  [ValidateRange(1, 100000)]
  [int] $UdpTargetMbps = 5000,

  [ValidateRange(1, 16)]
  [int] $ParallelStreams = 2,

  [ValidateRange(64, 65507)]
  [int] $UdpDatagramBytes = 1380,

  [ValidateRange(5, 600)]
  [int] $DurationSeconds = 30
)

$ErrorActionPreference = 'Stop'

function Invoke-VmShellScript {
  param(
    [Parameter(Mandatory)] [string] $VmName,
    [Parameter(Mandatory)] [string] $Script
  )

  $scriptFile = Join-Path ([System.IO.Path]::GetTempPath()) ("ilb-routing-test-{0}.sh" -f [guid]::NewGuid())
  ($Script -replace "`r`n", "`n") | Set-Content -NoNewline -Encoding utf8 $scriptFile

  try {
    $rawJson = az vm run-command invoke `
      --resource-group $ResourceGroupName `
      --name $VmName `
      --command-id RunShellScript `
      --scripts "@$scriptFile" `
      --query "value[0].message" `
      --output json

    if ($LASTEXITCODE -ne 0) {
      throw "Run command failed on '$VmName' with exit code $LASTEXITCODE."
    }
  }
  finally {
    Remove-Item -LiteralPath $scriptFile -ErrorAction SilentlyContinue
  }

  $raw = if ($rawJson) { [string](($rawJson -join "`n") | ConvertFrom-Json) } else { '' }
  $stdout = ''
  $stderr = ''
  if ($raw -match '(?s)\[stdout\](.*?)\[stderr\](.*)') {
    $stdout = $Matches[1].Trim()
    $stderr = $Matches[2].Trim()
  }
  else {
    $stdout = $raw.Trim()
  }

  [pscustomobject]@{
    Stdout = $stdout
    Stderr = $stderr
  }
}

function Get-ForwardedDatagrams {
  param([Parameter(Mandatory)] [string] $VmName)

  $result = Invoke-VmShellScript -VmName $VmName -Script @'
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
  if ($result.Stderr -or -not [long]::TryParse($result.Stdout.Trim(), [ref] $counter)) {
    throw "Could not read ForwDatagrams from '$VmName'. stdout: $($result.Stdout) stderr: $($result.Stderr)"
  }
  return $counter
}

function Assert-EffectiveRoute {
  param(
    [Parameter(Mandatory)] [string] $NicName,
    [Parameter(Mandatory)] [string] $DestinationPrefix,
    [Parameter(Mandatory)] [string] $ExpectedNextHopIp
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

  $nextHopIps = @($route.nextHopIpAddress)
  if ($route.nextHopType -ne 'VirtualAppliance' -or $nextHopIps -notcontains $ExpectedNextHopIp) {
    throw "Route '$DestinationPrefix' on '$NicName' uses $($route.nextHopType) [$($nextHopIps -join ', ')] instead of ILB $ExpectedNextHopIp."
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
$vm1Ip = $outputs.vm1PrivateIp.value
$vm1SubnetPrefix = $outputs.vm1SubnetPrefix.value
$vm2Name = $outputs.vm2Name.value
$vm2NicName = $outputs.vm2NicName.value
$vm2Ip = $outputs.vm2PrivateIp.value
$vm2SubnetPrefix = $outputs.vm2SubnetPrefix.value
$router1Name = $outputs.router1Name.value
$router1SecondaryIp = $outputs.router1SecondaryIp.value
$router2Name = $outputs.router2Name.value
$router2PrimaryIp = $outputs.router2PrimaryIp.value
$loadBalancerName = $outputs.loadBalancerName.value
$ilbFrontendIp = $outputs.loadBalancerFrontendIp.value
$backendPoolName = $outputs.backendPoolName.value

Write-Host 'Validating the 2+1 infra IP layout, sole ILB backend, and effective routes...'

foreach ($layout in @(
  @{ Nic = $outputs.router1NicName.value; Ips = @($outputs.router1PrimaryIp.value, $router1SecondaryIp) },
  @{ Nic = $outputs.router2NicName.value; Ips = @($router2PrimaryIp) }
)) {
  $nicIpsJson = az network nic show `
    --resource-group $ResourceGroupName `
    --name $layout.Nic `
    --query 'ipConfigurations[].privateIPAddress' `
    --output json
  if ($LASTEXITCODE -ne 0 -or -not $nicIpsJson) {
    throw "Could not read IP configurations for '$($layout.Nic)'."
  }
  $nicIps = @($nicIpsJson | ConvertFrom-Json)
  if ($nicIps.Count -ne $layout.Ips.Count -or @(Compare-Object $layout.Ips $nicIps).Count -ne 0) {
    throw "NIC '$($layout.Nic)' must have [$($layout.Ips -join ', ')]; actual: [$($nicIps -join ', ')]."
  }
}

$backendIpsJson = az network lb address-pool show `
  --resource-group $ResourceGroupName `
  --lb-name $loadBalancerName `
  --name $backendPoolName `
  --query 'loadBalancerBackendAddresses[].ipAddress' `
  --output json

if ($LASTEXITCODE -ne 0 -or -not $backendIpsJson) {
  throw "Could not read backend pool '$backendPoolName'."
}

$backendIps = @($backendIpsJson | ConvertFrom-Json)
if ($backendIps.Count -ne 1 -or $backendIps[0] -ne $router1SecondaryIp) {
  throw "Backend pool must contain only active secondary IP $router1SecondaryIp; actual: $($backendIps -join ', ')."
}

Assert-EffectiveRoute -NicName $vm1NicName -DestinationPrefix $vm2SubnetPrefix -ExpectedNextHopIp $ilbFrontendIp
Assert-EffectiveRoute -NicName $vm2NicName -DestinationPrefix $vm1SubnetPrefix -ExpectedNextHopIp $ilbFrontendIp

Write-Host "  backend pool : $router1SecondaryIp only" -ForegroundColor Green
Write-Host "  VM1 route    : $vm2SubnetPrefix via ILB $ilbFrontendIp" -ForegroundColor Green
Write-Host "  VM2 route    : $vm1SubnetPrefix via ILB $ilbFrontendIp" -ForegroundColor Green

$serverScript = @'
set -euo pipefail
IPERF=/usr/local/bin/iperf3
"$IPERF" --help 2>&1 | grep -q -- '--gsro'
listeners=$(ss -H -ltnp 'sport = :5201')
if [ -z "$listeners" ]; then
  "$IPERF" -s --daemon --port 5201
  sleep 2
  listeners=$(ss -H -ltnp 'sport = :5201')
fi
if [ -z "$listeners" ]; then
  echo "iperf3 did not start listening on TCP/5201" >&2
  exit 1
fi
for listener in $(printf '%s\n' "$listeners" | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u); do
  test "$(readlink -f "/proc/$listener/exe")" = "$(readlink -f "$IPERF")"
done
printf '%s\n' "$listeners" | grep -q 'pid='
echo IPERF_SERVER_STARTED
'@

$serverResult = Invoke-VmShellScript -VmName $vm2Name -Script $serverScript
if ($serverResult.Stdout -notmatch 'IPERF_SERVER_STARTED') {
  throw "Could not start iperf3 on '$vm2Name'. stdout: $($serverResult.Stdout) stderr: $($serverResult.Stderr)"
}

try {
  $router1Before = Get-ForwardedDatagrams -VmName $router1Name
  $router2Before = Get-ForwardedDatagrams -VmName $router2Name

  $streamRateMbps = [math]::Ceiling($UdpTargetMbps / $ParallelStreams)
  $effectiveTargetMbps = $streamRateMbps * $ParallelStreams

  $clientScript = @'
set -euo pipefail
TARGET=__TARGET_IP__
REPORT=/tmp/ilb-routing-udp.json
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
connected = report.get("start", {}).get("connected", [])
remote_host = connected[0].get("remote_host", "") if connected else ""

total_delta = int(sys.argv[4]) - int(sys.argv[2])
idle_delta = int(sys.argv[5]) - int(sys.argv[3])
vm_cpu = 100.0 * (total_delta - idle_delta) / total_delta

print(json.dumps({
    "remote_host": remote_host,
    "seconds": received["seconds"],
    "bits_per_second_sent": sent["bits_per_second"],
    "bits_per_second_received": received["bits_per_second"],
    "jitter_ms": received.get("jitter_ms", 0),
    "lost_packets": received.get("lost_packets", 0),
    "packets": received.get("packets", 0),
    "lost_percent": received.get("lost_percent", 0),
    "client_vm_cpu_percent": vm_cpu,
}, separators=(",", ":")))
PYEOF
'@ -replace '__TARGET_IP__', $vm2Ip `
     -replace '__STREAMS__', $ParallelStreams `
     -replace '__STREAM_RATE__', $streamRateMbps `
     -replace '__DATAGRAM_BYTES__', $UdpDatagramBytes `
     -replace '__DURATION__', $DurationSeconds

  $clientResult = Invoke-VmShellScript -VmName $vm1Name -Script $clientScript
  try {
    $result = $clientResult.Stdout | ConvertFrom-Json
  }
  catch {
    throw "Could not parse UDP result. stdout: $($clientResult.Stdout) stderr: $($clientResult.Stderr)"
  }

  $router1After = Get-ForwardedDatagrams -VmName $router1Name
  $router2After = Get-ForwardedDatagrams -VmName $router2Name
  $router1Delta = $router1After - $router1Before
  $router2Delta = $router2After - $router2Before

  if ($router1Delta -le 0) {
    throw "Router-1 did not forward any datagrams during the UDP test."
  }
  if ($router2Delta -ne 0) {
    throw "Router-2 forwarded $router2Delta datagrams even though it is not in the ILB backend pool."
  }

  Write-Host ''
  Write-Host '===================== ILB-routed UDP throughput =====================' -ForegroundColor Cyan
  Write-Host "  path               : $vm1Name -> $ilbFrontendIp -> $router1SecondaryIp -> $vm2Name"
  Write-Host "  inactive router    : $router2Name ($router2PrimaryIp, not in backend pool)"
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
  Write-Host '=====================================================================' -ForegroundColor Cyan
}
finally {
  Write-Host "The iperf3 server on '$vm2Name' remains running for subsequent tests."
}
