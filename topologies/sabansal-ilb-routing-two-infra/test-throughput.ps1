[CmdletBinding()]
param(
  [string] $ResourceGroupName = 'sabansal-ilb-routing-two-infra-rg',

  [string] $DeploymentName = 'sabansal-ilb-routing-two-infra',

  [ValidateSet('router1', 'router2')]
  [string] $BackendRouter = 'router2',

  [switch] $ConnectivityOnly,

  [ValidateRange(1, 30)]
  [int] $ConnectivityTimeoutSeconds = 5,

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
    [string] $Operation = 'guest script',
    [ValidateRange(5, 900)] [int] $TimeoutSeconds = 30
  )

  $scriptFile = Join-Path ([System.IO.Path]::GetTempPath()) ("ilb-routing-test-{0}.sh" -f [guid]::NewGuid())
  $cliStderrFile = "$scriptFile.stderr"
  $exitMarker = "ILB_GUEST_EXIT_$([guid]::NewGuid().ToString('N'))"
  $delimiter = "ILB_SCRIPT_$([guid]::NewGuid().ToString('N'))"
  $wrappedScript = @"
timeout --signal=TERM --kill-after=5s ${TimeoutSeconds}s /bin/bash -s <<'$delimiter'
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
    [ValidateSet('', 'swift-ilb-router1', 'swift-ilb-backend2')]
    [string] $NamespaceName = ''
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
  $prefix = if ($NamespaceName) { "ip netns exec $NamespaceName " } else { '' }
  $context = if ($NamespaceName) { $NamespaceName } else { 'inactive host root' }
  $result = Invoke-VmShellScript -VmName $VmName -Operation "ForwDatagrams in $context" -TimeoutSeconds 15 `
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
    [ValidateSet('swift-ilb-router1', 'swift-ilb-backend2')]
    [string] $NamespaceName,
    [Parameter(Mandatory)] [ValidateSet(1, 2)] [int] $VlanId,
    [bool] $Active = $true
  )

  $guestScript = @'
set -euo pipefail
python3 - <<'PYEOF'
import json
import subprocess

def ip_json(*args):
    return json.loads(subprocess.check_output(["ip", "-j", *args], text=True, timeout=10))

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
    "customerIps": [],
}
for entry in result["namespaces"]:
    links = ip_json("-n", entry, "-4", "addr", "show")
    result["customerIps"] += [
        {"namespace": entry, "ip": address["local"]}
        for link in links for address in link.get("addr_info", [])
        if address["local"].startswith("10.80.")
    ]
raw = subprocess.check_output(["/usr/local/bin/swiftcmd", "get-all-ncs"], text=True, timeout=15)
report = json.loads(raw[raw.index("{"):])
entries = report.get("networkContainers", report.get("NetworkContainers"))
if entries is None and ("networkContainers" in report or "NetworkContainers" in report):
    entries = []
if not isinstance(entries, list):
    raise RuntimeError("Unrecognized SWIFT NC inventory")
result["ncIds"] = [entry.get("networkContainerId") or entry["NetworkContainerId"] for entry in entries]
if namespace in result["namespaces"]:
    result["namespaceAddresses"] = ip_json("-n", namespace, "-4", "addr", "show", "dev", "swift0")
    result["namespaceLinks"] = ip_json("-n", namespace, "-d", "link", "show", "dev", "swift0")
    result["forwarding"] = subprocess.check_output(
        ["ip", "netns", "exec", namespace, "sysctl", "-n", "net.ipv4.ip_forward"], text=True, timeout=10
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
    $_.ifname -in @('swiftvlan1', 'swiftvlan2') -or
    ($_.linkinfo.info_kind -eq 'vlan' -and $_.linkinfo.info_data.id -in @(1, 2))
  }).Count -ne 0) {
    throw "Router '$VmName' must have no root routing VLAN 1/2; the backend VLAN must reside inside its namespace."
  }
  if (-not $Active) {
    if (@($guest.ncIds).Count -ne 0 -or @($guest.customerIps).Count -ne 0 -or
        @($guest.namespaces | Where-Object { $_ -in @('swift-ilb-router1', 'swift-ilb-router2', 'swift-ilb-backend2') }).Count -ne 0) {
      throw "Inactive router '$VmName' must have no NC or customer SWIFT attachment (including legacy .6)."
    }
    return
  }
  $interfaces = @($guest.namespaceAddresses)
  $links = @($guest.namespaceLinks)
  $addresses = @($interfaces | ForEach-Object { $_.addr_info })
  if (@($guest.namespaces) -notcontains $NamespaceName -or
      $interfaces.Count -ne 1 -or $interfaces[0].ifname -ne 'swift0' -or
      $links.Count -ne 1 -or $links[0].ifname -ne 'swift0' -or
      $links[0].linkinfo.info_kind -ne 'vlan' -or $links[0].linkinfo.info_data.id -ne $VlanId -or
      $addresses.Count -ne 1 -or $addresses[0].local -ne '10.80.0.5' -or
      $addresses[0].prefixlen -ne 32 -or @($guest.ncIds).Count -ne 1 -or
      @($guest.customerIps).Count -ne 1 -or $guest.customerIps[0].ip -ne '10.80.0.5' -or
      $guest.customerIps[0].namespace -ne $NamespaceName -or
      @($guest.namespaces | Where-Object {
        $_ -in @('swift-ilb-router1', 'swift-ilb-router2', 'swift-ilb-backend2') -and $_ -ne $NamespaceName
      }).Count -ne 0) {
    throw "Router '$VmName' must have exactly one SWIFT NC with VLAN swift0 (VLAN $VlanId), sole IP 10.80.0.5/32 in $NamespaceName, and no .6 attachment."
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
$routerNamespaceName = if ($BackendRouter -eq 'router1') { 'swift-ilb-router1' } else { 'swift-ilb-backend2' }
$routingVlanId = if ($BackendRouter -eq 'router1') { 1 } else { 2 }
$router2Name = $outputs.router2Name.value
$router2PrimaryIp = $outputs.router2PrimaryIp.value
$loadBalancerName = $outputs.loadBalancerName.value
$ilbFrontendIp = $outputs.loadBalancerFrontendIp.value
$backendPoolName = $outputs.backendPoolName.value

if ($outputs.router1PrimaryIp.value -ne '10.30.0.4' -or $router2PrimaryIp -ne '10.30.0.5' -or
    $routingBackendIp -ne '10.80.0.5' -or
    $vm1Ip -ne '10.80.1.4' -or $vm2Ip -ne '10.80.2.4') {
  throw 'Deployment outputs do not match the isolated infra/SWIFT routing topology.'
}
$activeName = if ($BackendRouter -eq 'router1') { $router1Name } else { $router2Name }
$inactiveName = if ($BackendRouter -eq 'router1') { $router2Name } else { $router1Name }
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
  -NamespaceName $routerNamespaceName -VlanId $routingVlanId -Active ($BackendRouter -eq 'router1')
Assert-RouterGuestLayout -VmName $router2Name -PrimaryIp $router2PrimaryIp `
  -NamespaceName $routerNamespaceName -VlanId $routingVlanId -Active ($BackendRouter -eq 'router2')

Assert-EffectiveRoute -NicName $vm1NicName -DestinationPrefix $vm2SubnetPrefix -ExpectedNextHopIp $ilbFrontendIp
Assert-EffectiveRoute -NicName $vm2NicName -DestinationPrefix $vm1SubnetPrefix -ExpectedNextHopIp $ilbFrontendIp

Write-Host "  backend pool : $routingBackendIp only (SWIFT namespace $routerNamespaceName)" -ForegroundColor Green
Write-Host "  active router: $activeName, VLAN $routingVlanId; $inactiveName has no NC" -ForegroundColor Green
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

$serverResult = Invoke-VmShellScript -VmName $vm2Name -Operation 'persistent iperf3 listener' -TimeoutSeconds 15 -Script $serverScript
if ($serverResult.Stdout -notmatch 'IPERF_SERVER_STARTED') {
  throw "Could not start iperf3 on '$vm2Name'."
}

try {
  $activeBefore = Get-ForwardedDatagrams -VmName $activeName -NamespaceName $routerNamespaceName
  $inactiveBefore = Get-ForwardedDatagrams -VmName $inactiveName
  foreach ($direction in @(
    @{ Name = $vm1Name; Target = $vm2Ip; Tcp = 1 },
    @{ Name = $vm2Name; Target = $vm1Ip; Tcp = 0 }
  )) {
    $connectivityScript = @'
set -euo pipefail
ping -c 2 -W 1 -w __TIMEOUT__ __TARGET__ >/dev/null
if [ __TCP__ = 1 ]; then
  python3 - <<'PY'
import socket
with socket.create_connection(("__TARGET__", 5201), timeout=__TIMEOUT__):
    pass
PY
fi
echo CONNECTIVITY_OK
'@
    $connectivityScript = $connectivityScript.Replace('__TIMEOUT__', [string]$ConnectivityTimeoutSeconds).
      Replace('__TARGET__', $direction.Target).Replace('__TCP__', [string]$direction.Tcp)
    $check = Invoke-VmShellScript -VmName $direction.Name -Operation "connectivity to $($direction.Target)" `
      -TimeoutSeconds (2 * $ConnectivityTimeoutSeconds + 5) -Script $connectivityScript
    if ($check.Stdout -ne 'CONNECTIVITY_OK') { throw "Connectivity check failed on $($direction.Name)." }
  }
  $activeAfterConnectivity = Get-ForwardedDatagrams -VmName $activeName -NamespaceName $routerNamespaceName
  $inactiveAfterConnectivity = Get-ForwardedDatagrams -VmName $inactiveName
  $activeDelta = $activeAfterConnectivity - $activeBefore
  $inactiveDelta = $inactiveAfterConnectivity - $inactiveBefore
  if ($activeDelta -le 0 -or $inactiveDelta -ne 0) {
    throw "Connectivity forwarding isolation failed: backend namespace delta=$activeDelta, inactive root delta=$inactiveDelta."
  }
  if ($ConnectivityOnly) {
    Write-Host "Bidirectional ICMP and VM1 -> VM2 TCP/5201 succeeded through $BackendRouter ($routerNamespaceName); inactive root forwarding stayed unchanged." -ForegroundColor Green
    return
  }
  $activeBefore = $activeAfterConnectivity
  $inactiveBefore = $inactiveAfterConnectivity

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

read -r _ cpu_user cpu_nice cpu_system cpu_idle cpu_iowait cpu_irq cpu_softirq cpu_steal _ </proc/stat
CPU_TOTAL_BEFORE=$((cpu_user + cpu_nice + cpu_system + cpu_idle + cpu_iowait + cpu_irq + cpu_softirq + cpu_steal))
CPU_IDLE_BEFORE=$((cpu_idle + cpu_iowait))

REPORT_READY=1
timeout --signal=TERM --kill-after=5s __CLIENT_TIMEOUT__s "$IPERF" -c "$TARGET" -p 5201 -u -P __STREAMS__ -b __STREAM_RATE__M \
  --connect-timeout __CONNECT_TIMEOUT_MS__ \
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
     -replace '__DURATION__', $DurationSeconds `
     -replace '__CLIENT_TIMEOUT__', ($DurationSeconds + $ConnectivityTimeoutSeconds + 10) `
     -replace '__CONNECT_TIMEOUT_MS__', ($ConnectivityTimeoutSeconds * 1000)

  $clientResult = Invoke-VmShellScript -VmName $vm1Name -Operation 'UDP GSRO client' `
    -TimeoutSeconds ($DurationSeconds + $ConnectivityTimeoutSeconds + 20) -Script $clientScript
  try {
    $result = $clientResult.Stdout | ConvertFrom-Json
  }
  catch {
    throw 'Could not parse UDP result.'
  }

  $activeAfter = Get-ForwardedDatagrams -VmName $activeName -NamespaceName $routerNamespaceName
  $inactiveAfter = Get-ForwardedDatagrams -VmName $inactiveName
  $activeDelta = $activeAfter - $activeBefore
  $inactiveDelta = $inactiveAfter - $inactiveBefore

  if ($activeDelta -le 0) {
    throw "Backend router $activeName did not forward any datagrams in $routerNamespaceName."
  }
  if ($inactiveDelta -ne 0) {
    throw "Inactive router $inactiveName forwarded $inactiveDelta datagrams in root despite having no NC."
  }

  Write-Host ''
  Write-Host '===================== ILB-routed UDP throughput =====================' -ForegroundColor Cyan
  Write-Host "  path               : $vm1Name -> $ilbFrontendIp -> $routingBackendIp ($routerNamespaceName) -> $vm2Name"
  Write-Host "  inactive router    : $inactiveName (no SWIFT NC)"
  Write-Host "  offered rate       : $effectiveTargetMbps Mbits/sec"
  Write-Host "  streams            : $ParallelStreams"
  Write-Host "  datagram           : $UdpDatagramBytes bytes"
  Write-Host ("  duration           : {0:N1} seconds" -f $result.seconds)
  Write-Host ("  sent               : {0:N2} Gbits/sec" -f ($result.bits_per_second_sent / 1e9))
  Write-Host ("  received           : {0:N2} Gbits/sec" -f ($result.bits_per_second_received / 1e9)) -ForegroundColor Green
  Write-Host ("  packet loss        : {0:N2}% ({1:N0}/{2:N0})" -f $result.lost_percent, $result.lost_packets, $result.packets)
  Write-Host ("  jitter             : {0:N3} ms" -f $result.jitter_ms)
  Write-Host ("  VM1 CPU            : {0:N1}%" -f $result.client_vm_cpu_percent)
  Write-Host ("  backend forwarded  : {0:N0} datagrams in {1}" -f $activeDelta, $routerNamespaceName)
  Write-Host ("  inactive forwarded : {0:N0} datagrams in root" -f $inactiveDelta)
  Write-Host '=====================================================================' -ForegroundColor Cyan
}
finally {
  Write-Host "The iperf3 server on '$vm2Name' remains running for subsequent tests."
}
