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

function Protect-VmDiagnosticText {
  param([AllowEmptyString()] [string] $Text)

  foreach ($pattern in @(
    '(?i)(/authenticationToken/)[^/\s"''<>]+',
    '(?i)(--(?:auth|access|refresh)-token(?:=|\s+))(?:"[^"]*"|''[^'']*''|[^\s]+)',
    '(?i)(["'']?\b(?:auth(?:entication)?[_-]?token|access[_-]?token|refresh[_-]?token)["'']?\s*[:=]\s*)(?:"[^"]*"|''[^'']*''|[^\s,;&}\]]+)',
    '(?i)(\\["''](?:auth(?:entication)?[_-]?token|access[_-]?token|refresh[_-]?token)\\["'']\s*:\s*\\["''])[^\\]*',
    '(?i)(\b(?:Bearer|Basic)\s+)[A-Za-z0-9._~+/-]+=*'
  )) {
    $Text = [regex]::Replace($Text, $pattern, '$1[REDACTED]')
  }
  return $Text
}

function Invoke-VmShellScript {
  param(
    [Parameter(Mandatory)] [string] $VmName,
    [Parameter(Mandatory)] [string] $Script,
    [string] $Operation = 'guest script'
  )

  $scriptFile = Join-Path ([System.IO.Path]::GetTempPath()) ("ilb-routing-test-{0}.sh" -f [guid]::NewGuid())
  $cliStderrFile = "$scriptFile.stderr"
  $exitMarker = "ILB_GUEST_EXIT_$([guid]::NewGuid().ToString('N'))"
  $delimiter = "ILB_SCRIPT_$([guid]::NewGuid().ToString('N'))"
  $wrappedScript = @"
/bin/bash -s <<'$delimiter'
$Script
$delimiter
guest_exit=`$?
printf '\n$exitMarker=%s\n' "`$guest_exit"
exit "`$guest_exit"
"@
  ($wrappedScript -replace "`r`n", "`n") | Set-Content -NoNewline -Encoding utf8 $scriptFile

  try {
    $rawJson = az vm run-command invoke `
      --resource-group $ResourceGroupName `
      --name $VmName `
      --command-id RunShellScript `
      --scripts "@$scriptFile" `
      --query value `
      --output json 2> $cliStderrFile
    $cliExitCode = $LASTEXITCODE
    $cliStderr = if (Test-Path -LiteralPath $cliStderrFile) {
      Get-Content -LiteralPath $cliStderrFile -Raw
    } else { '' }
  }
  finally {
    Remove-Item -LiteralPath $scriptFile, $cliStderrFile -ErrorAction SilentlyContinue
  }

  $rawResponse = $rawJson -join "`n"
  $invalidJson = $false
  try {
    $statuses = @($rawResponse | ConvertFrom-Json | Where-Object { $null -ne $_ })
  }
  catch {
    $statuses = @()
    $invalidJson = $true
  }
  $raw = if ($statuses.Count) {
    ($statuses | ForEach-Object { $_.message }) -join "`n"
  } else { $rawResponse }
  $stdout = ''
  $stderr = ''
  $stdoutStatuses = @($statuses | Where-Object { $_.code -match '(?i)/StdOut/' })
  $stderrStatuses = @($statuses | Where-Object { $_.code -match '(?i)/StdErr/' })
  if ($stdoutStatuses.Count -or $stderrStatuses.Count) {
    $stdout = (($stdoutStatuses | ForEach-Object { $_.message }) -join "`n").Trim()
    $stderr = (($stderrStatuses | ForEach-Object { $_.message }) -join "`n").Trim()
  }
  elseif ($raw -match '(?s)\[stdout\](.*?)\[stderr\](.*)') {
    $stdout = $Matches[1].Trim()
    $stderr = $Matches[2].Trim()
  }
  else {
    $stdout = $raw.Trim()
  }

  $exitPattern = "(?m)^$exitMarker=(\d+)\s*$"
  $exitMatches = [regex]::Matches($stdout, $exitPattern)
  $guestExit = if ($exitMatches.Count -eq 1) {
    $exitMatches[0].Groups[1].Value
  } elseif ($exitMatches.Count -eq 0) { 'missing completion marker' } else { 'multiple completion markers' }
  $failureReason = if ($cliExitCode -ne 0) {
    'Azure CLI Run Command failed'
  } elseif ($invalidJson) {
    'Azure CLI returned invalid Run Command JSON'
  } elseif (-not $statuses.Count -or @($statuses | Where-Object {
    $_.code -match '(?i)(failed|error)' -or $_.level -eq 'Error'
  }).Count -gt 0) {
    'Azure guest Run Command status failed or was missing'
  } elseif ($exitMatches.Count -ne 1 -or $guestExit -ne '0') {
    'Guest script failed or did not report completion'
  } else { '' }
  if ($failureReason) {
    $statusSummary = ConvertTo-Json -InputObject @($statuses | Select-Object code, level, displayStatus) -Compress
    $diagnostics = Protect-VmDiagnosticText -Text @"
$failureReason on '$VmName' ($Operation).
Run Command: az vm run-command invoke --resource-group $ResourceGroupName --name $VmName --command-id RunShellScript
Azure CLI exit: $cliExitCode
Guest exit: $guestExit
Azure statuses: $statusSummary
[stdout]
$stdout
[stderr]
$stderr
[Azure CLI stderr]
$cliStderr
"@
    throw $diagnostics
  }
  $stdout = ([regex]::Replace($stdout, $exitPattern, '')).Trim()
  if ($stderr) {
    Write-Warning (Protect-VmDiagnosticText -Text "Guest stderr on '$VmName' ($Operation):`n$stderr")
  }
  if ($cliStderr) {
    Write-Warning (Protect-VmDiagnosticText -Text $cliStderr.Trim())
  }

  [pscustomobject]@{
    Stdout = $stdout
    Stderr = $stderr
  }
}

function Get-ForwardedDatagrams {
  param(
    [Parameter(Mandatory)] [string] $VmName,
    [Parameter(Mandatory)]
    [ValidateSet('swift-ilb-router1', 'swift-ilb-router2')]
    [string] $NamespaceName
  )

  $counterScript = @'
set -euo pipefail
__NAMESPACE_PREFIX__awk '$1 == "Ip:" {
  if (++line == 1) {
    for (i = 1; i <= NF; i++) if ($i == "ForwDatagrams") column = i
  } else if (column) {
    print $column
  }
}' /proc/net/snmp
'@
  $prefix = "ip netns exec $NamespaceName "
  $result = Invoke-VmShellScript -VmName $VmName -Operation "ForwDatagrams in $NamespaceName" `
    -Script ($counterScript.Replace('__NAMESPACE_PREFIX__', $prefix))

  [long] $counter = 0
  if (-not [long]::TryParse($result.Stdout.Trim(), [ref] $counter)) {
    throw "Could not read ForwDatagrams from '$VmName' (namespace: '$NamespaceName')."
  }
  return $counter
}

function Assert-RouterGuestLayout {
  param(
    [Parameter(Mandatory)] [string] $VmName,
    [Parameter(Mandatory)] [string] $PrimaryIp,
    [Parameter(Mandatory)]
    [ValidateSet('swift-ilb-router1', 'swift-ilb-router2')]
    [string] $NamespaceName,
    [Parameter(Mandatory)]
    [ValidateSet('10.80.0.5', '10.80.0.6')]
    [string] $SwiftIp
  )

  $guestScript = @'
set -euo pipefail
python3 - <<'PYEOF'
import json
import subprocess

def ip_json(*args):
    return json.loads(subprocess.check_output(["ip", "-j", *args], text=True))

namespace = "__NAMESPACE__"
root = ip_json("-4", "addr", "show")
namespaces = ip_json("netns", "list")
result = {
    "rootAddresses": [address["local"] for link in root for address in link.get("addr_info", [])],
    "rootLinks": ip_json("-d", "link", "show"),
    "namespaces": [entry["name"] for entry in namespaces],
    "namespaceAddresses": [],
    "namespaceLinks": [],
    "forwarding": None,
}
if namespace in result["namespaces"]:
    result["namespaceAddresses"] = ip_json("-n", namespace, "-4", "addr", "show", "dev", "swift0")
    result["namespaceLinks"] = ip_json("-n", namespace, "-d", "link", "show", "dev", "swift0")
    result["forwarding"] = subprocess.check_output(
        ["ip", "netns", "exec", namespace, "sysctl", "-n", "net.ipv4.ip_forward"], text=True
    ).strip()
print(json.dumps(result, separators=(",", ":")))
PYEOF
'@
  $guestScript = $guestScript.Replace('__NAMESPACE__', $NamespaceName)
  $guestResult = Invoke-VmShellScript -VmName $VmName -Operation "SWIFT layout in $NamespaceName" -Script $guestScript
  $guest = $guestResult.Stdout | ConvertFrom-Json
  if (@($guest.rootAddresses) -notcontains $PrimaryIp -or
      @($guest.rootAddresses | Where-Object { $_ -like '10.80.*' }).Count -ne 0) {
    throw "Router '$VmName' must own infra IP $PrimaryIp and no customer IPs in the root namespace."
  }
  $rootLinks = @($guest.rootLinks | Where-Object { $null -ne $_ })
  if (-not $rootLinks.Count -or @($rootLinks | Where-Object {
    $_.ifname -eq 'swiftvlan1' -or
    ($_.linkinfo.info_kind -eq 'vlan' -and $_.linkinfo.info_data.id -eq 1)
  }).Count -ne 0) {
    throw "Router '$VmName' must have no root swiftvlan1 or routing VLAN 1; the routing VLAN must reside inside $NamespaceName."
  }
  $interfaces = @($guest.namespaceAddresses)
  $links = @($guest.namespaceLinks)
  $addresses = @($interfaces | ForEach-Object { $_.addr_info })
  if (@($guest.namespaces) -notcontains $NamespaceName -or
      $interfaces.Count -ne 1 -or $interfaces[0].ifname -ne 'swift0' -or
      $links.Count -ne 1 -or $links[0].ifname -ne 'swift0' -or
      $links[0].linkinfo.info_kind -ne 'vlan' -or $links[0].linkinfo.info_data.id -ne 1 -or
      $addresses.Count -ne 1 -or $addresses[0].local -ne $SwiftIp -or
      $addresses[0].prefixlen -ne 32) {
    throw "Router '$VmName' must have SWIFT VLAN interface swift0 (VLAN 1) with sole IP $SwiftIp/32 in $NamespaceName."
  }
  if ($guest.forwarding -ne '1') {
    throw "IPv4 forwarding must be enabled inside $NamespaceName on '$VmName'."
  }
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
$routingBackendIp = $outputs.routingBackendIp.value
$routerNamespaceName = $outputs.routerNamespaceName.value
$router2Name = $outputs.router2Name.value
$router2PrimaryIp = $outputs.router2PrimaryIp.value
$router2SwiftIp = $outputs.router2SwiftIp.value
$router2NamespaceName = $outputs.router2NamespaceName.value
$loadBalancerName = $outputs.loadBalancerName.value
$ilbFrontendIp = $outputs.loadBalancerFrontendIp.value
$backendPoolName = $outputs.backendPoolName.value

if ($outputs.router1PrimaryIp.value -ne '10.30.0.4' -or $router2PrimaryIp -ne '10.30.0.5' -or
    $routingBackendIp -ne '10.80.0.5' -or $outputs.router1SecondaryIp.value -ne $routingBackendIp -or
    $routerNamespaceName -ne 'swift-ilb-router1' -or $outputs.routingVlanId.value -ne 1 -or
    $router2SwiftIp -ne '10.80.0.6' -or $router2NamespaceName -ne 'swift-ilb-router2' -or
    $outputs.router2VlanId.value -ne 1 -or
    $vm1Ip -ne '10.80.1.4' -or $vm2Ip -ne '10.80.2.4') {
  throw 'Deployment outputs do not match the isolated infra/SWIFT routing topology.'
}
[System.Net.IPAddress] $frontendAddress = $null
if (-not [System.Net.IPAddress]::TryParse([string] $ilbFrontendIp, [ref] $frontendAddress) -or
    $frontendAddress.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
  throw 'Deployment must provide a valid IPv4 loadBalancerFrontendIp output.'
}
$infraVnetId = [string] $outputs.infraVnetId.value
$customerVnetId = [string] $outputs.customerVnetId.value
$routingSubnetId = [string] $outputs.routingSubnetId.value
if ([string]::IsNullOrWhiteSpace($infraVnetId) -or [string]::IsNullOrWhiteSpace($customerVnetId) -or
    $infraVnetId -eq $customerVnetId -or [string]::IsNullOrWhiteSpace($outputs.customerVnetGuid.value) -or
    [string]::IsNullOrWhiteSpace($outputs.routingSubnetName.value) -or
    $routingSubnetId -ne "$customerVnetId/subnets/$($outputs.routingSubnetName.value)") {
  throw 'Deployment must identify distinct infra/customer VNets and a routing subnet in the customer VNet.'
}

Write-Host 'Validating isolated infra NICs, the sole SWIFT ILB backend, namespace forwarding, and effective routes...'

foreach ($layout in @(
  @{ Nic = $outputs.router1NicName.value; Ip = $outputs.router1PrimaryIp.value },
  @{ Nic = $outputs.router2NicName.value; Ip = $router2PrimaryIp }
)) {
  $nicJson = az network nic show `
    --resource-group $ResourceGroupName `
    --name $layout.Nic `
    --output json
  if ($LASTEXITCODE -ne 0 -or -not $nicJson) {
    throw "Could not read IP configurations for '$($layout.Nic)'."
  }
  $nic = $nicJson | ConvertFrom-Json
  $configurations = @($nic.ipConfigurations)
  if ($configurations.Count -ne 1 -or $configurations[0].privateIPAddress -ne $layout.Ip -or
      $configurations[0].primary -ne $true) {
    throw "NIC '$($layout.Nic)' must have exactly one primary infra IP $($layout.Ip), with no native customer/backend IP."
  }
  $subnetId = [string] $configurations[0].subnet.id
  if (-not $subnetId.StartsWith("$infraVnetId/subnets/", [System.StringComparison]::OrdinalIgnoreCase) -or
      $subnetId.StartsWith("$customerVnetId/subnets/", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "NIC '$($layout.Nic)' must belong to the infra VNet, not the customer VNet."
  }
}

$backendPoolJson = az network lb address-pool show `
  --resource-group $ResourceGroupName `
  --lb-name $loadBalancerName `
  --name $backendPoolName `
  --output json

if ($LASTEXITCODE -ne 0 -or -not $backendPoolJson) {
  throw "Could not read backend pool '$backendPoolName'."
}

$backendPool = $backendPoolJson | ConvertFrom-Json
$backends = @($backendPool.loadBalancerBackendAddresses)
if ($backends.Count -ne 1 -or $backends[0].ipAddress -ne $routingBackendIp -or
    $backends[0].virtualNetwork.id -ne $customerVnetId -or
    @($backendPool.backendIPConfigurations | Where-Object { $null -ne $_ }).Count -gt 0) {
  throw "Backend pool must contain only IP-based SWIFT backend $routingBackendIp mapped to the customer VNet, with no NIC-based backends."
}

Assert-RouterGuestLayout -VmName $router1Name -PrimaryIp $outputs.router1PrimaryIp.value `
  -NamespaceName $routerNamespaceName -SwiftIp $routingBackendIp
Assert-RouterGuestLayout -VmName $router2Name -PrimaryIp $router2PrimaryIp `
  -NamespaceName $router2NamespaceName -SwiftIp $router2SwiftIp

Assert-EffectiveRoute -NicName $vm1NicName -DestinationPrefix $vm2SubnetPrefix -ExpectedNextHopIp $ilbFrontendIp
Assert-EffectiveRoute -NicName $vm2NicName -DestinationPrefix $vm1SubnetPrefix -ExpectedNextHopIp $ilbFrontendIp

Write-Host "  backend pool : $routingBackendIp only (SWIFT namespace $routerNamespaceName)" -ForegroundColor Green
Write-Host "  excluded IP  : $router2SwiftIp (SWIFT namespace $router2NamespaceName)" -ForegroundColor Green
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

$serverResult = Invoke-VmShellScript -VmName $vm2Name -Operation 'persistent iperf3 listener' -Script $serverScript
if ($serverResult.Stdout -notmatch 'IPERF_SERVER_STARTED') {
  throw "Could not start iperf3 on '$vm2Name'."
}

try {
  $router1Before = Get-ForwardedDatagrams -VmName $router1Name -NamespaceName $routerNamespaceName
  $router2Before = Get-ForwardedDatagrams -VmName $router2Name -NamespaceName $router2NamespaceName
  if ($router2Before -ne 0) {
    throw "Router-2 namespace $router2NamespaceName ForwDatagrams must be zero before the UDP test."
  }

  $streamRateMbps = [math]::Ceiling($UdpTargetMbps / $ParallelStreams)
  $effectiveTargetMbps = $streamRateMbps * $ParallelStreams

  $clientScript = @'
set -euo pipefail
TARGET=__TARGET_IP__
REPORT=/tmp/ilb-routing-udp.json
IPERF=/usr/local/bin/iperf3
REPORT_READY=0
trap 'rc=$?; printf "UDP client failed at line %s (exit %s): %s\n" "$LINENO" "$rc" "$BASH_COMMAND" >&2; if [ "$REPORT_READY" = 1 ] && [ -s "$REPORT" ]; then cat "$REPORT" >&2; fi; exit "$rc"' ERR
"$IPERF" --help 2>&1 | grep -q -- '--gsro'
ping -c 3 -W 3 "$TARGET" >/dev/null

read -r _ cpu_user cpu_nice cpu_system cpu_idle cpu_iowait cpu_irq cpu_softirq cpu_steal _ </proc/stat
CPU_TOTAL_BEFORE=$((cpu_user + cpu_nice + cpu_system + cpu_idle + cpu_iowait + cpu_irq + cpu_softirq + cpu_steal))
CPU_IDLE_BEFORE=$((cpu_idle + cpu_iowait))

REPORT_READY=1
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

  $clientResult = Invoke-VmShellScript -VmName $vm1Name -Operation 'UDP GSRO client' -Script $clientScript
  try {
    $result = $clientResult.Stdout | ConvertFrom-Json
  }
  catch {
    throw 'Could not parse UDP result.'
  }

  $router1After = Get-ForwardedDatagrams -VmName $router1Name -NamespaceName $routerNamespaceName
  $router2After = Get-ForwardedDatagrams -VmName $router2Name -NamespaceName $router2NamespaceName
  $router1Delta = $router1After - $router1Before
  $router2Delta = $router2After - $router2Before

  if ($router1Delta -le 0) {
    throw "Router-1 did not forward any datagrams during the UDP test."
  }
  if ($router2After -ne 0 -or $router2Delta -ne 0) {
    throw "Router-2 namespace $router2NamespaceName forwarded $router2Delta datagrams even though $router2SwiftIp is not in the ILB backend pool."
  }

  Write-Host ''
  Write-Host '===================== ILB-routed UDP throughput =====================' -ForegroundColor Cyan
  Write-Host "  path               : $vm1Name -> $ilbFrontendIp -> $routingBackendIp ($routerNamespaceName) -> $vm2Name"
  Write-Host "  inactive router    : $router2Name (infra $router2PrimaryIp; SWIFT $router2SwiftIp in $router2NamespaceName, not in backend pool)"
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
