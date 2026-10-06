[CmdletBinding()]
param(
  [string] $ResourceGroupName = 'sabansal-wireguard-sea-rg',
  [string] $DeploymentName = 'sabansal-wireguard',
  [string] $SshUser = 'azureuser',
  [ValidateSet('gsocap', 'stock')] [string] $Build = 'gsocap',
  [ValidateRange(1, 64)] [int] $MaxTransmitSegments = 44,
  [ValidateRange(1, 1024)] [int] $MaxTransmitDatagrams = 88,
  [ValidateRange(1, 16)] [int] $Pairs = 3,
  [ValidateRange(1, 600)] [int] $DurationSeconds = 30,
  [ValidateSet('cubic', 'bbr', 'new-reno')] [string] $CongestionControl = 'cubic',
  [string] $ConnectionWindow = '64M',
  [string] $StreamWindow = '16M',
  [string] $SocketBuffer = '8M',
  [ValidateRange(1200, 1472)] [int] $MaxUdpPayloadBytes = 1472,
  [switch] $Reverse,
  [switch] $SkipInstall,
  [string] $OutputPath
)

$ErrorActionPreference = 'Stop'
$sshOptions = @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', '-o', 'StrictHostKeyChecking=accept-new')

# One GSO send must fit in a single 64 KiB UDP datagram.
$maxSegmentsForPayload = [math]::Floor(65507 / $MaxUdpPayloadBytes)
if ($Build -eq 'gsocap' -and $MaxTransmitSegments -gt $maxSegmentsForPayload) {
  throw "MaxTransmitSegments $MaxTransmitSegments exceeds the 64 KiB GSO limit ($maxSegmentsForPayload x $MaxUdpPayloadBytes bytes)."
}

function Invoke-Remote([string] $Ip, [string] $Script) {
  $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Script -replace "`r", '') + "`n"))
  $output = & ssh @sshOptions "$SshUser@$Ip" "printf '%s' '$encoded' | base64 -d | bash" 2>&1
  $code = $LASTEXITCODE
  $lines = @($output | ForEach-Object { "$_" } | Where-Object { $_ -notmatch '^Authorized use only' })
  if ($code -ne 0) { throw "Remote command on $Ip failed ($code): $($lines -join "`n")" }
  $lines
}

$raw = az deployment group show --resource-group $ResourceGroupName --name $DeploymentName `
  --query properties.outputs --output json
if ($LASTEXITCODE -ne 0) { throw "Cannot resolve deployment '$DeploymentName'." }
$outputs = ($raw -join "`n") | ConvertFrom-Json
$server = [pscustomobject]@{ PrivateIp = $outputs.serverPrivateIp.value; PublicIp = $outputs.serverPublicIp.value }
$client = [pscustomobject]@{ PrivateIp = $outputs.clientPrivateIp.value; PublicIp = $outputs.clientPublicIp.value }
if (-not ($server.PrivateIp -and $server.PublicIp -and $client.PrivateIp -and $client.PublicIp)) {
  throw 'Deployment outputs are missing VM IP addresses.'
}

if (-not $SkipInstall) {
  $installScript = (Get-Content -Raw (Join-Path $PSScriptRoot 'quinn-benchmark\install.sh')) -replace "`r", ''
  $encodedInstall = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($installScript))
  $jobs = foreach ($ip in @($server.PublicIp, $client.PublicIp)) {
    Start-Job -ArgumentList $ip, $SshUser, $encodedInstall, (, $sshOptions) -ScriptBlock {
      param($Ip, $User, $Encoded, $Options)
      $output = & ssh @Options "$User@$Ip" "printf '%s' '$Encoded' | base64 -d >/tmp/quinn-install.sh && sudo bash /tmp/quinn-install.sh >/tmp/quinn-build.log 2>&1; rc=`$?; tail -n 20 /tmp/quinn-build.log; rm -f /tmp/quinn-install.sh; exit `$rc" 2>&1
      [pscustomobject]@{ Ip = $Ip; Code = $LASTEXITCODE; Output = ($output -join "`n") }
    }
  }
  $results = $jobs | Wait-Job | Receive-Job
  $jobs | Remove-Job
  foreach ($result in $results) {
    if ($result.Code -ne 0) { throw "quinn build failed on $($result.Ip):`n$($result.Output)" }
  }
}

$binary = if ($Build -eq 'gsocap') { 'quinn-perf-gsocap' } else { 'quinn-perf' }
$exe = "env QUINN_MAX_TRANSMIT_SEGMENTS=$MaxTransmitSegments QUINN_MAX_TRANSMIT_DATAGRAMS=$MaxTransmitDatagrams /opt/quinn-perf/bin/$binary"
$common = "--send-buffer-size $SocketBuffer --recv-buffer-size $SocketBuffer --initial-mtu $MaxUdpPayloadBytes --max-udp-payload-size $MaxUdpPayloadBytes --congestion $CongestionControl --receive-window $ConnectionWindow --stream-receive-window $StreamWindow --send-window $ConnectionWindow"
# Forward: the server VM sends (download). Reverse: the client VM sends (upload).
$sizes = if ($Reverse) { '--download-size 0 --upload-size 1000G' } else { '--upload-size 0 --download-size 1000G' }
$cpuSample = 'read -r _ u n s i w q sq st _ < /proc/stat; echo "$((u+n+s+q+sq+st)) $((u+n+s+q+sq+st+i+w))"'
function Get-CpuPercent($Before, $After) {
  $a = "$Before" -split ' '; $b = "$After" -split ' '
  [math]::Round(100 * ([double]$b[0] - [double]$a[0]) / ([double]$b[1] - [double]$a[1]), 1)
}

$stopServers = "pkill -f '^/opt/quinn-perf/bin/' || true"
$startServers = "$stopServers`nsleep 0.5`n"
for ($p = 0; $p -lt $Pairs; $p++) {
  $startServers += "nohup $exe server --listen $($server.PrivateIp):$(5433 + $p) $common >/tmp/quinn-server-$p.log 2>&1 </dev/null &`n"
}
$startServers += "sleep 1`ntest `"`$(pgrep -fc '^/opt/quinn-perf/bin/')`" -eq $Pairs"

$runClients = "rm -f /tmp/quinn-client-*.json`n"
for ($p = 0; $p -lt $Pairs; $p++) {
  $runClients += "$exe client $($server.PrivateIp):$(5433 + $p) --bi-requests 1 $sizes --duration $DurationSeconds --interval $DurationSeconds --json /tmp/quinn-client-$p.json $common >/tmp/quinn-client-$p.log 2>&1 </dev/null &`n"
}
$runClients += @'
wait
python3 - <<'PY'
import glob, json
rates = []
for path in sorted(glob.glob('/tmp/quinn-client-*.json')):
    data = json.load(open(path))
    total_bytes = sum(i['sum']['bytes'] for i in data['intervals'])
    seconds = sum(i['sum']['seconds'] for i in data['intervals'])
    rates.append(total_bytes * 8 / seconds / 1e9)
print('QUINN_RESULT=' + json.dumps({'per_connection_gbps': rates, 'goodput_gbps': sum(rates)}))
PY
'@

$quicheWasActive = @{}
try {
  foreach ($ip in @($server.PublicIp, $client.PublicIp)) {
    $quicheWasActive[$ip] = (Invoke-Remote $ip 'systemctl is-active quiche-benchmark || true') -contains 'active'
    if ($quicheWasActive[$ip]) { Invoke-Remote $ip 'sudo systemctl stop quiche-benchmark' | Out-Null }
  }
  Invoke-Remote $server.PublicIp $startServers | Out-Null
  $serverBefore = Invoke-Remote $server.PublicIp $cpuSample
  $clientBefore = Invoke-Remote $client.PublicIp $cpuSample
  $clientOutput = Invoke-Remote $client.PublicIp $runClients
  $serverAfter = Invoke-Remote $server.PublicIp $cpuSample
  $clientAfter = Invoke-Remote $client.PublicIp $cpuSample
  $sourceInfo = (Invoke-Remote $client.PublicIp 'cat /opt/quinn-perf/source.json') | ConvertFrom-Json
}
finally {
  Invoke-Remote $server.PublicIp $stopServers | Out-Null
  foreach ($ip in $quicheWasActive.Keys) {
    if ($quicheWasActive[$ip]) { Invoke-Remote $ip 'sudo systemctl start quiche-benchmark' | Out-Null }
  }
}

$resultLine = $clientOutput | Where-Object { $_ -like 'QUINN_RESULT=*' } | Select-Object -Last 1
if (-not $resultLine) { throw "No quinn result:`n$($clientOutput -join "`n")" }
$measurement = $resultLine.Substring('QUINN_RESULT='.Length) | ConvertFrom-Json
$result = [ordered]@{
  measured_at = (Get-Date).ToUniversalTime().ToString('o')
  direction = if ($Reverse) { 'client-to-server' } else { 'server-to-client' }
  build = $Build
  quinn = $sourceInfo
  max_transmit_segments = if ($Build -eq 'gsocap') { $MaxTransmitSegments } else { 10 }
  max_transmit_datagrams = if ($Build -eq 'gsocap') { $MaxTransmitDatagrams } else { 20 }
  pairs = $Pairs
  duration_seconds = $DurationSeconds
  congestion_control = $CongestionControl
  connection_window = $ConnectionWindow
  stream_window = $StreamWindow
  socket_buffer = $SocketBuffer
  max_udp_payload_bytes = $MaxUdpPayloadBytes
  goodput_gbps = [math]::Round($measurement.goodput_gbps, 3)
  per_connection_gbps = @($measurement.per_connection_gbps | ForEach-Object { [math]::Round($_, 3) })
  client_cpu_percent = Get-CpuPercent $clientBefore $clientAfter
  server_cpu_percent = Get-CpuPercent $serverBefore $serverAfter
}
$json = $result | ConvertTo-Json -Depth 5
if ($OutputPath) { Set-Content -Path $OutputPath -Value $json -Encoding utf8 }
$json
Write-Host ("quinn {0} goodput: {1} Gbit/s; client CPU {2}%, server CPU {3}%" -f $Build, $result.goodput_gbps, $result.client_cpu_percent, $result.server_cpu_percent)
