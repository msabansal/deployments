<#
.SYNOPSIS
  Sends traffic from VM1 to VM2 through the router VM and verifies that VM2 observes VM1's
  original private IP as the source address.

.DESCRIPTION
  Resolves VM1 and VM2 from the deployment outputs, verifies that VM1's next hop towards VM2
  is the router, and runs a source-address probe that VM2 must observe as coming from VM1.
  It then runs a single script on VM1 that drives a parallel
  stream iperf3 test. Because both steps live in the same script, a failed path check aborts
  the run before any traffic is measured, so a throughput number is only ever reported for
  traffic that actually went through the router. When the router is Linux the kernel's
  ForwDatagrams counter is sampled either side of the test as a second, independent
  confirmation that the router forwarded the traffic itself.

.EXAMPLE
  .\test-connectivity.ps1 -ResourceGroupName sabansal-routing-rg
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $ResourceGroupName,

  [string] $DeploymentName = 'sabansal-routing',

  [ValidateRange(1, 128)]
  [int] $ParallelConnections = 8,

  [ValidateRange(5, 3600)]
  [int] $DurationSeconds = 60,

  [int] $Port = 5201,

  [switch] $Reverse,

  [switch] $SkipPathCheck,

  [switch] $PassThru
)

$ErrorActionPreference = 'Stop'

function Invoke-VmShellScript {
  param(
    [Parameter(Mandatory)] [string] $VmName,
    [Parameter(Mandatory)] [string] $Script
  )

  # A multi-line string passed straight to --scripts is split by the CLI, so only the first
  # line runs and the remaining lines shadow later arguments such as --query. Passing the
  # script through a file with the @ prefix keeps it intact. LF endings matter because the
  # script is executed by bash on Linux.
  $scriptFile = Join-Path ([System.IO.Path]::GetTempPath()) ("vmscript-{0}.sh" -f [guid]::NewGuid())
  ($Script -replace "`r`n", "`n") | Set-Content -NoNewline -Encoding utf8 $scriptFile

  try {
    # -o json keeps the message as a single string. With -o tsv a multi-line message comes
    # back as a string array, and -match on an array filters instead of populating $Matches.
    $rawJson = az vm run-command invoke `
      --resource-group $ResourceGroupName `
      --name $VmName `
      --command-id RunShellScript `
      --scripts "@$scriptFile" `
      --query "value[0].message" `
      -o json

    if ($LASTEXITCODE -ne 0) {
      throw "Run command failed on $VmName with exit code $LASTEXITCODE."
    }
  }
  finally {
    Remove-Item -LiteralPath $scriptFile -ErrorAction SilentlyContinue
  }

  $raw = ''
  if ($rawJson) {
    $converted = ($rawJson -join "`n" | ConvertFrom-Json)
    if ($converted -is [string]) { $raw = $converted }
    else { $raw = [string]$converted }
  }

  # The message is "Enable succeeded: \n[stdout]\n<out>\n[stderr]\n<err>".
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

function Format-Bits {
  param([double] $BitsPerSecond)

  if ($BitsPerSecond -ge 1e9) { return '{0:N2} Gbits/sec' -f ($BitsPerSecond / 1e9) }
  if ($BitsPerSecond -ge 1e6) { return '{0:N2} Mbits/sec' -f ($BitsPerSecond / 1e6) }
  if ($BitsPerSecond -ge 1e3) { return '{0:N2} Kbits/sec' -f ($BitsPerSecond / 1e3) }
  return '{0:N0} bits/sec' -f $BitsPerSecond
}

Write-Host "Resolving deployment '$DeploymentName' in resource group '$ResourceGroupName'..."

$outputsJson = az deployment group show `
  --resource-group $ResourceGroupName `
  --name $DeploymentName `
  --query properties.outputs `
  -o json

if ($LASTEXITCODE -ne 0) {
  throw "Could not read outputs of deployment '$DeploymentName'. Deploy the topology first."
}

$outputs = $outputsJson | ConvertFrom-Json

$endpointAVm = if ($outputs.vm1Name.value) { $outputs.vm1Name.value } else { $outputs.endpointAVmName.value }
$endpointBVm = if ($outputs.vm2Name.value) { $outputs.vm2Name.value } else { $outputs.endpointBVmName.value }
$endpointAIp = if ($outputs.vm1PrivateIp.value) { $outputs.vm1PrivateIp.value } else { $outputs.endpointAPrivateIp.value }
$endpointBIp = if ($outputs.vm2PrivateIp.value) { $outputs.vm2PrivateIp.value } else { $outputs.endpointBPrivateIp.value }
$routerVm = $outputs.routerVmName.value
$routerIp = $outputs.routerPrivateIp.value
$routerOs = $outputs.routerOperatingSystem.value
$testPortBounds = @($outputs.testPortRange.value -split '-', 2)

if (-not $endpointAVm -or -not $endpointBVm) {
  throw 'The deployment outputs do not contain the endpoint VM names. Redeploy with the current main.bicep.'
}
if ($testPortBounds.Count -ne 2) {
  throw 'The deployment output testPortRange is missing or invalid. Redeploy with the current main.bicep.'
}

$testPortStart = [int] $testPortBounds[0]
$testPortEnd = [int] $testPortBounds[1]
$sourceProbePort = if ($Port -lt $testPortEnd) { $Port + 1 } elseif ($Port -gt $testPortStart) { $Port - 1 } else { 0 }
if ($Port -lt $testPortStart -or $Port -gt $testPortEnd) {
  throw "Port $Port is outside the deployed test port range $testPortStart-$testPortEnd."
}
if ($sourceProbePort -eq 0) {
  throw 'The deployed test port range must contain at least two ports: one for iperf3 and one for the source-address probe.'
}

Write-Host ''
Write-Host "  VM1    : $endpointAVm ($endpointAIp)"
Write-Host "  VM2    : $endpointBVm ($endpointBIp)"
Write-Host "  router : $routerVm ($routerIp, $routerOs)"
Write-Host "  test   : $ParallelConnections parallel streams for $DurationSeconds seconds on port $Port"
Write-Host ''

Write-Host 'Verifying that VM2 sees VM1 as the source, without SNAT on the router...'

$sourceProbeServerScript = @"
pkill -f '/tmp/vm-source-probe.py' 2>/dev/null || true
rm -f /tmp/vm-source-probe-result
cat >/tmp/vm-source-probe.py <<'PYEOF'
import socket

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("0.0.0.0", $sourceProbePort))
server.listen(1)
connection, peer = server.accept()
connection.recv(1)
with open("/tmp/vm-source-probe-result", "w") as result:
    result.write(peer[0])
connection.sendall(b"ok")
connection.close()
server.close()
PYEOF
nohup python3 /tmp/vm-source-probe.py >/tmp/vm-source-probe.log 2>&1 &
sleep 1
if kill -0 `$! 2>/dev/null; then
  echo "source probe listening on port $sourceProbePort"
else
  cat /tmp/vm-source-probe.log >&2
  exit 1
fi
"@

$sourceProbeServerResult = Invoke-VmShellScript -VmName $endpointBVm -Script $sourceProbeServerScript
if ($sourceProbeServerResult.Stderr) {
  throw "Could not start the source-address probe on VM2: $($sourceProbeServerResult.Stderr)"
}

$sourceProbeClientScript = @'
set -euo pipefail
ROUTER_IP=__ROUTER_IP__
TARGET=__SERVER_IP__

if command -v traceroute >/dev/null 2>&1; then
  FIRST_HOP=$(traceroute -n -m 3 -w 2 -q 1 "$TARGET" 2>/dev/null | awk 'NR==2 {print $2}')
else
  FIRST_HOP=$(ip route get "$TARGET" | awk '{for(i=1;i<=NF;i++) if ($i=="via") print $(i+1)}')
fi
FIRST_HOP=${FIRST_HOP:-none}

if [ "__ENFORCE_PATH__" = "1" ] && [ "$FIRST_HOP" != "$ROUTER_IP" ]; then
  echo "path check failed: the first hop towards $TARGET is $FIRST_HOP but the router is $ROUTER_IP" >&2
  exit 1
fi

python3 - "$TARGET" __PORT__ <<'PYEOF'
import socket
import sys

connection = socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=10)
connection.sendall(b"x")
if connection.recv(2) != b"ok":
    raise RuntimeError("VM2 did not acknowledge the source-address probe")
connection.close()
PYEOF

echo "$FIRST_HOP"
'@ -replace '__SERVER_IP__', $endpointBIp `
   -replace '__ROUTER_IP__', $routerIp `
   -replace '__ENFORCE_PATH__', $(if ($SkipPathCheck) { '0' } else { '1' }) `
   -replace '__PORT__', $sourceProbePort

$sourceProbeClientResult = Invoke-VmShellScript -VmName $endpointAVm -Script $sourceProbeClientScript
if ($sourceProbeClientResult.Stderr) {
  throw "The VM1 source-address probe failed: $($sourceProbeClientResult.Stderr)"
}

$sourceProbeResult = Invoke-VmShellScript -VmName $endpointBVm -Script @'
for attempt in $(seq 1 10); do
  if [ -s /tmp/vm-source-probe-result ]; then
    cat /tmp/vm-source-probe-result
    exit 0
  fi
  sleep 1
done
echo "the source-address probe did not record a peer address" >&2
exit 1
'@

$observedSourceIp = $sourceProbeResult.Stdout.Trim()
if ($sourceProbeResult.Stderr -or -not $observedSourceIp) {
  throw "Could not read the source address observed by VM2: $($sourceProbeResult.Stderr)"
}
if ($observedSourceIp -ne $endpointAIp) {
  throw "Source IP was not preserved. VM2 observed $observedSourceIp, but VM1 is $endpointAIp."
}

Write-Host "  first hop : $($sourceProbeClientResult.Stdout.Trim())" -ForegroundColor Green
Write-Host "  source IP : $observedSourceIp (VM1 address preserved)" -ForegroundColor Green
Write-Host ''
Write-Host 'Starting the iperf3 server on VM2...'

$serverScript = @"
pkill -f 'iperf3 -s' 2>/dev/null || true
sleep 1
nohup iperf3 -s -p $Port --daemon >/var/log/iperf3-server.log 2>&1
sleep 2
if pgrep -f 'iperf3 -s' >/dev/null; then
  echo "iperf3 server listening on port $Port"
else
  echo "iperf3 server failed to start" >&2
  exit 1
fi
"@

$serverResult = Invoke-VmShellScript -VmName $endpointBVm -Script $serverScript
Write-Host "  $($serverResult.Stdout)"

if ($serverResult.Stderr) {
  throw "Could not start the iperf3 server: $($serverResult.Stderr)"
}

try {
  [long] $forwardedDatagramsBefore = 0
  $forwardedDatagrams = $null
  if ($routerOs -eq 'AzureLinux') {
    $counterResult = Invoke-VmShellScript -VmName $routerVm -Script @'
awk '$1 == "Ip:" {
  if (++line == 1) {
    for (i = 1; i <= NF; i++) if ($i == "ForwDatagrams") column = i
  } else if (column) {
    print $column
  }
}' /proc/net/snmp
'@
    if ($counterResult.Stderr -or -not [long]::TryParse($counterResult.Stdout.Trim(), [ref] $forwardedDatagramsBefore)) {
      throw "Could not read the router's ForwDatagrams counter: $($counterResult.Stderr)"
    }
  }

  $direction = if ($Reverse) { '--reverse' } else { '' }
  $clientTimeout = $DurationSeconds + 30

  Write-Host "Running iperf3 for $DurationSeconds seconds. This will take a little over $([math]::Round($DurationSeconds / 60.0, 1)) minutes..."

  # Azure keeps only the last few kilobytes of a run-command's stdout, and a full iperf3 JSON
  # report is far larger than that. Write the report to a file on the VM and return only the
  # fields the summary needs so the payload stays well inside the limit.
  $clientScript = @'
set -u
REPORT=/tmp/iperf3-report.json
ROUTER_IP=__ROUTER_IP__
TARGET=__SERVER_IP__

# Path check. It runs on the client VM immediately before the transfer so the throughput
# figure can never be reported for traffic that did not go through the router.
if command -v traceroute >/dev/null 2>&1; then
  FIRST_HOP=$(traceroute -n -m 3 -w 2 -q 1 "$TARGET" 2>/dev/null | awk 'NR==2 {print $2}')
else
  FIRST_HOP=$(ip route get "$TARGET" | awk '{for(i=1;i<=NF;i++) if ($i=="via") print $(i+1)}')
fi
FIRST_HOP=${FIRST_HOP:-none}

if [ "__ENFORCE_PATH__" = "1" ] && [ "$FIRST_HOP" != "$ROUTER_IP" ]; then
  echo "{\"error\":\"path check failed: the first hop towards $TARGET is $FIRST_HOP but the router is $ROUTER_IP, so the throughput test was not run\"}"
  exit 0
fi

rm -f "$REPORT"
timeout __TIMEOUT__ iperf3 -c "$TARGET" -p __PORT__ -P __STREAMS__ -t __DURATION__ __DIRECTION__ --json > "$REPORT" 2>/tmp/iperf3-error.txt
FIRST_HOP="$FIRST_HOP" python3 - "$REPORT" <<'PYEOF'
import json, os, sys

try:
    with open(sys.argv[1]) as handle:
        report = json.load(handle)
except Exception as exc:
    print(json.dumps({"error": "could not read the iperf3 report: %s" % exc}))
    sys.exit(0)

if report.get("error"):
    print(json.dumps({"error": report["error"]}))
    sys.exit(0)

end = report.get("end", {})
summary = {
    "first_hop": os.environ.get("FIRST_HOP", ""),
    "end": {
        "sum_sent": end.get("sum_sent", {}),
        "sum_received": end.get("sum_received", {}),
        "cpu_utilization_percent": end.get("cpu_utilization_percent", {}),
        "streams": [
            {
                "sender": {
                    "bits_per_second": stream.get("sender", {}).get("bits_per_second", 0),
                    "retransmits": stream.get("sender", {}).get("retransmits", 0),
                }
            }
            for stream in end.get("streams", [])
        ],
    }
}
print(json.dumps(summary, separators=(",", ":")))
PYEOF
'@ -replace '__TIMEOUT__', $clientTimeout `
   -replace '__SERVER_IP__', $endpointBIp `
   -replace '__ROUTER_IP__', $routerIp `
   -replace '__ENFORCE_PATH__', $(if ($SkipPathCheck) { '0' } else { '1' }) `
   -replace '__PORT__', $Port `
   -replace '__STREAMS__', $ParallelConnections `
   -replace '__DURATION__', $DurationSeconds `
   -replace '__DIRECTION__', $direction

  $clientResult = Invoke-VmShellScript -VmName $endpointAVm -Script $clientScript

  if (-not $clientResult.Stdout) {
    throw "iperf3 produced no output. stderr: $($clientResult.Stderr)"
  }

  try {
    $report = $clientResult.Stdout | ConvertFrom-Json
  }
  catch {
    throw "Could not parse the iperf3 output as JSON. Raw output:`n$($clientResult.Stdout)`nstderr: $($clientResult.Stderr)"
  }

  if ($report.error) {
    throw "iperf3 reported an error: $($report.error)"
  }

  $sent = $report.end.sum_sent
  $received = $report.end.sum_received
  $cpu = $report.end.cpu_utilization_percent
  $streamCount = @($report.end.streams).Count

  if ($routerOs -eq 'AzureLinux') {
    $counterResult = Invoke-VmShellScript -VmName $routerVm -Script @'
awk '$1 == "Ip:" {
  if (++line == 1) {
    for (i = 1; i <= NF; i++) if ($i == "ForwDatagrams") column = i
  } else if (column) {
    print $column
  }
}' /proc/net/snmp
'@
    [long] $forwardedDatagramsAfter = 0
    if ($counterResult.Stderr -or -not [long]::TryParse($counterResult.Stdout.Trim(), [ref] $forwardedDatagramsAfter)) {
      throw "Could not read the router's ForwDatagrams counter after the transfer: $($counterResult.Stderr)"
    }
    $forwardedDatagrams = $forwardedDatagramsAfter - $forwardedDatagramsBefore
    if ($forwardedDatagrams -le 0) {
      throw "The router's ForwDatagrams counter did not increase during the transfer."
    }
  }

  Write-Host ''
  Write-Host '================ throughput summary ================' -ForegroundColor Cyan
  Write-Host ("  path                 : {0} -> {1} -> {2}" -f $endpointAIp, $routerIp, $endpointBIp)
  Write-Host ("  first hop verified   : {0}" -f $report.first_hop) -ForegroundColor Green
  Write-Host ("  source IP at VM2     : {0} (VM1 preserved)" -f $observedSourceIp) -ForegroundColor Green
  Write-Host ("  direction            : {0}" -f $(if ($Reverse) { 'server to client' } else { 'client to server' }))
  Write-Host ("  parallel streams     : {0}" -f $streamCount)
  Write-Host ("  duration             : {0:N1} seconds" -f $sent.seconds)
  Write-Host ("  bytes sent           : {0:N2} GB" -f ($sent.bytes / 1GB))
  Write-Host ("  throughput sent      : {0}" -f (Format-Bits $sent.bits_per_second)) -ForegroundColor Green
  Write-Host ("  throughput received  : {0}" -f (Format-Bits $received.bits_per_second)) -ForegroundColor Green
  Write-Host ("  TCP retransmits      : {0:N0}" -f $sent.retransmits)

  if ($cpu) {
    Write-Host ("  client CPU (sender)  : {0:N1} %" -f $cpu.host_total)
    Write-Host ("  server CPU (receiver): {0:N1} %" -f $cpu.remote_total)
  }
  if ($null -ne $forwardedDatagrams) {
    Write-Host ("  datagrams forwarded  : {0:N0}" -f $forwardedDatagrams) -ForegroundColor Green
  }

  Write-Host '====================================================' -ForegroundColor Cyan
  Write-Host ''

  Write-Host 'Per-stream throughput:'
  $index = 0
  foreach ($stream in $report.end.streams) {
    $index++
    Write-Host ("  stream {0,-3} {1,18}  retransmits {2:N0}" -f $index, (Format-Bits $stream.sender.bits_per_second), $stream.sender.retransmits)
  }

  if ($sent.retransmits -gt 0) {
    $lossRatio = $sent.retransmits / [math]::Max($sent.bytes / 1460.0, 1)
    Write-Host ''
    Write-Host ("Retransmit ratio is {0:P4} of segments sent." -f $lossRatio)
  }

  if ($PassThru) {
    [pscustomobject]@{
      ResourceGroupName    = $ResourceGroupName
      ClientVmName         = $endpointAVm
      ServerVmName         = $endpointBVm
      RouterVmName         = $routerVm
      RouterOperatingSystem = $routerOs
      FirstHop             = $report.first_hop
      SourceIpObservedByVm2 = $observedSourceIp
      SourceIpPreserved    = $observedSourceIp -eq $endpointAIp
      ParallelConnections  = $streamCount
      DurationSeconds      = $sent.seconds
      BytesSent            = $sent.bytes
      BitsPerSecondSent    = $sent.bits_per_second
      BitsPerSecondReceived = $received.bits_per_second
      GbpsSent             = [math]::Round($sent.bits_per_second / 1e9, 3)
      GbpsReceived         = [math]::Round($received.bits_per_second / 1e9, 3)
      Retransmits          = $sent.retransmits
      ForwardedDatagrams   = $forwardedDatagrams
      TimestampUtc         = (Get-Date).ToUniversalTime()
    }
  }
}
finally {
  # Stopping the server is best effort. A cleanup error must not turn a test that already
  # produced a measurement into a failure, and the VM may legitimately be gone by now, for
  # example when the resource group is being torn down.
  Write-Host ''
  Write-Host 'Cleaning up...'
  try {
    Invoke-VmShellScript -VmName $endpointBVm -Script "pkill -f 'iperf3 -s' 2>/dev/null || true; echo stopped" | Out-Null
    Write-Host '  iperf3 server stopped.'
  }
  catch {
    Write-Warning "  could not stop the iperf3 server on $endpointBVm : $($_.Exception.Message)"
  }
}
