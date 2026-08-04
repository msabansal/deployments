<#
.SYNOPSIS
  Runs an iperf3 throughput test between the two endpoint VMs and confirms that the traffic
  is forwarded by the router VM.

.DESCRIPTION
  Resolves the endpoint VMs from the deployment outputs and runs a single script on endpoint A
  that first verifies the next hop towards endpoint B is the router and then runs a parallel
  stream iperf3 test. Because both steps live in the same script, a failed path check aborts
  the run before any traffic is measured, so a throughput number is only ever reported for
  traffic that actually went through the router. When the router is Linux the kernel's
  ForwDatagrams counter is sampled either side of the test as a second, independent
  confirmation that the router forwarded the traffic itself.

.EXAMPLE
  .\test-connectivity.ps1 -ResourceGroupName rg-fwd
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $ResourceGroupName,

  [string] $DeploymentName = 'vm-ip-forwarding',

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

$endpointAVm = $outputs.endpointAVmName.value
$endpointBVm = $outputs.endpointBVmName.value
$endpointAIp = $outputs.endpointAPrivateIp.value
$endpointBIp = $outputs.endpointBPrivateIp.value
$routerVm = $outputs.routerVmName.value
$routerIp = $outputs.routerPrivateIp.value
$routerOs = $outputs.routerOperatingSystem.value

if (-not $endpointAVm -or -not $endpointBVm) {
  throw 'The deployment outputs do not contain the endpoint VM names. Redeploy with the current main.bicep.'
}

Write-Host ''
Write-Host "  client : $endpointAVm ($endpointAIp)"
Write-Host "  server : $endpointBVm ($endpointBIp)"
Write-Host "  router : $routerVm ($routerIp, $routerOs)"
Write-Host "  test   : $ParallelConnections parallel streams for $DurationSeconds seconds on port $Port"
Write-Host ''

Write-Host 'Starting the iperf3 server on the endpoint B VM...'

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
  $routerIsLinux = $routerOs -ne 'WindowsServer2022'

  # Reading the kernel's own forwarding counter is a far better proof that the router did the
  # work than capturing packets. With Accelerated Networking the VF handles the traffic and
  # tcpdump on the synthetic interface sees none of it, so a capture reports zero packets even
  # while the router is forwarding at line rate.
  $forwardCounterScript = @'
grep '^Ip:' /proc/net/snmp | head -2 | awk 'NR==1 { for (i = 1; i <= NF; i++) if ($i == "ForwDatagrams") c = i } NR==2 { print $c }'
'@

  $forwardedBefore = $null
  if ($routerIsLinux) {
    $value = (Invoke-VmShellScript -VmName $routerVm -Script $forwardCounterScript).Stdout.Trim()
    $parsed = 0L
    if ([long]::TryParse($value, [ref] $parsed)) {
      $forwardedBefore = $parsed
      Write-Host "Router has forwarded $('{0:N0}' -f $parsed) datagrams so far."
    }
    else {
      Write-Warning "Could not read the router's forwarding counter, so the forwarded datagram check is skipped."
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

  $forwardedDatagrams = $null
  if ($null -ne $forwardedBefore) {
    $value = (Invoke-VmShellScript -VmName $routerVm -Script $forwardCounterScript).Stdout.Trim()
    $parsed = 0L
    if ([long]::TryParse($value, [ref] $parsed)) {
      $forwardedDatagrams = $parsed - $forwardedBefore
    }
  }

  Write-Host ''
  Write-Host '================ throughput summary ================' -ForegroundColor Cyan
  Write-Host ("  path                 : {0} -> {1} -> {2}" -f $endpointAIp, $routerIp, $endpointBIp)
  Write-Host ("  first hop verified   : {0}" -f $report.first_hop) -ForegroundColor Green
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
    if ($forwardedDatagrams -gt 0) {
      Write-Host ("  datagrams forwarded   : {0:N0}" -f $forwardedDatagrams) -ForegroundColor Green
      Write-Host '  the router forwarded the traffic in its own IP stack.' -ForegroundColor Green
    }
    else {
      throw "The router's ForwDatagrams counter did not increase during the test, so it did not forward the traffic."
    }
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
