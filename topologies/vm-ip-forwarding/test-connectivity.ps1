<#
.SYNOPSIS
  Runs an iperf3 throughput test between the two endpoint VMs and confirms that the traffic
  is forwarded by the router VM.

.DESCRIPTION
  Resolves the endpoint VMs from the deployment outputs, verifies that the first hop from
  endpoint A towards endpoint B is the router, runs a parallel-stream iperf3 test, and prints
  a summary. A packet capture on the router runs alongside the test to prove that the traffic
  actually traversed it rather than taking a direct path.

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

  [switch] $SkipPathCheck
)

$ErrorActionPreference = 'Stop'

function Invoke-VmShellScript {
  param(
    [Parameter(Mandatory)] [string] $VmName,
    [Parameter(Mandatory)] [string] $Script
  )

  $raw = az vm run-command invoke `
    --resource-group $ResourceGroupName `
    --name $VmName `
    --command-id RunShellScript `
    --scripts $Script `
    --query "value[0].message" `
    -o tsv

  if ($LASTEXITCODE -ne 0) {
    throw "Run command failed on $VmName with exit code $LASTEXITCODE."
  }

  # The message is "Enable succeeded: \n[stdout]\n<out>\n[stderr]\n<err>".
  $stdout = ''
  $stderr = ''
  if ($raw -match '(?s)\[stdout\](.*?)\[stderr\](.*)') {
    $stdout = $Matches[1].Trim()
    $stderr = $Matches[2].Trim()
  }
  else {
    $stdout = ($raw ?? '').Trim()
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

if (-not $SkipPathCheck) {
  Write-Host 'Verifying that the first hop towards the server is the router...'

  $pathScript = @'
if command -v traceroute >/dev/null 2>&1; then
  traceroute -n -m 3 -w 2 -q 1 __TARGET__ 2>/dev/null | awk 'NR==2 {print $2}'
else
  ip route get __TARGET__ | awk '{for(i=1;i<=NF;i++) if ($i=="via") print $(i+1)}'
fi
'@ -replace '__TARGET__', $endpointBIp

  $firstHop = (Invoke-VmShellScript -VmName $endpointAVm -Script $pathScript).Stdout.Trim()

  if ($firstHop -eq $routerIp) {
    Write-Host "  first hop is $firstHop, which is the router." -ForegroundColor Green
  }
  else {
    Write-Warning "First hop towards $endpointBIp is '$firstHop' but the router is $routerIp. Traffic may be bypassing the router."
  }
  Write-Host ''
}

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
  $captureSeconds = $DurationSeconds + 15
  $routerIsLinux = $routerOs -ne 'WindowsServer2022'

  if ($routerIsLinux) {
    Write-Host 'Starting a packet capture on the router...'

    $captureScript = @'
pkill -f "tcpdump -ni" 2>/dev/null || true
rm -f /tmp/router-capture.count
nohup sh -c "timeout __SECONDS__ tcpdump -ni any -q 'host __IP_A__ and host __IP_B__' 2>/dev/null | wc -l > /tmp/router-capture.count" >/dev/null 2>&1 &
sleep 2
echo "capture running for __SECONDS__ seconds"
'@ -replace '__SECONDS__', $captureSeconds -replace '__IP_A__', $endpointAIp -replace '__IP_B__', $endpointBIp

    (Invoke-VmShellScript -VmName $routerVm -Script $captureScript) | Out-Null
  }

  $direction = if ($Reverse) { '--reverse' } else { '' }
  $clientTimeout = $DurationSeconds + 30

  Write-Host "Running iperf3 for $DurationSeconds seconds. This will take a little over $([math]::Round($DurationSeconds / 60.0, 1)) minutes..."

  $clientScript = @"
timeout $clientTimeout iperf3 -c $endpointBIp -p $Port -P $ParallelConnections -t $DurationSeconds $direction --json
"@

  $clientResult = Invoke-VmShellScript -VmName $endpointAVm -Script $clientScript

  if (-not $clientResult.Stdout) {
    throw "iperf3 produced no output. stderr: $($clientResult.Stderr)"
  }

  try {
    $report = $clientResult.Stdout | ConvertFrom-Json
  }
  catch {
    throw "Could not parse the iperf3 output as JSON. Raw output:`n$($clientResult.Stdout)"
  }

  if ($report.error) {
    throw "iperf3 reported an error: $($report.error)"
  }

  $sent = $report.end.sum_sent
  $received = $report.end.sum_received
  $cpu = $report.end.cpu_utilization_percent
  $streamCount = @($report.end.streams).Count

  $capturedPackets = $null
  if ($routerIsLinux) {
    $countScript = @'
for i in $(seq 1 20); do
  if [ -s /tmp/router-capture.count ]; then break; fi
  sleep 1
done
cat /tmp/router-capture.count 2>/dev/null || echo 0
'@
    $capturedPackets = (Invoke-VmShellScript -VmName $routerVm -Script $countScript).Stdout.Trim()
  }

  Write-Host ''
  Write-Host '================ throughput summary ================' -ForegroundColor Cyan
  Write-Host ("  path                 : {0} -> {1} -> {2}" -f $endpointAIp, $routerIp, $endpointBIp)
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

  if ($null -ne $capturedPackets) {
    $packetCount = 0
    if ([int]::TryParse($capturedPackets, [ref] $packetCount) -and $packetCount -gt 0) {
      Write-Host ("  packets seen on router: {0:N0}" -f $packetCount) -ForegroundColor Green
      Write-Host '  traffic confirmed to traverse the router.' -ForegroundColor Green
    }
    else {
      Write-Warning '  the router captured no packets between the endpoints; traffic may be bypassing it.'
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
}
finally {
  Write-Host ''
  Write-Host 'Cleaning up...'
  Invoke-VmShellScript -VmName $endpointBVm -Script "pkill -f 'iperf3 -s' 2>/dev/null || true; echo stopped" | Out-Null
  Write-Host '  iperf3 server stopped.'
}
