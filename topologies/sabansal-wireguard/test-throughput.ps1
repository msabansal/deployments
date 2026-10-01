[CmdletBinding()]
param(
  [string] $ResourceGroupName = 'sabansal-wireguard-rg',

  [string] $DeploymentName = 'sabansal-wireguard',

  [ValidateSet('WireGuard', 'Direct')]
  [string] $Path = 'WireGuard',

  [ValidateRange(1, 32)]
  [int] $ParallelConnections = 4,

  [ValidateRange(1, 10000)]
  [int] $UdpTargetMbps = 2000,

  [ValidateRange(5, 600)]
  [int] $DurationSeconds = 30
)

$ErrorActionPreference = 'Stop'

function Invoke-VmShellScript {
  param(
    [Parameter(Mandatory)] [string] $VmName,
    [Parameter(Mandatory)] [string] $Script
  )

  $scriptFile = Join-Path ([System.IO.Path]::GetTempPath()) ("wireguard-test-{0}.sh" -f [guid]::NewGuid())
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

$outputsJson = az deployment group show `
  --resource-group $ResourceGroupName `
  --name $DeploymentName `
  --query properties.outputs `
  --output json

if ($LASTEXITCODE -ne 0 -or -not $outputsJson) {
  throw "Could not read outputs from deployment '$DeploymentName'."
}

$outputs = $outputsJson | ConvertFrom-Json
$serverVmName = $outputs.serverVmName.value
$clientVmName = $outputs.clientVmName.value
$serverTunnelIp = $outputs.serverTunnelIp.value
$serverPrivateIp = $outputs.serverPrivateIp.value
$targetIp = if ($Path -eq 'WireGuard') { $serverTunnelIp } else { $serverPrivateIp }

$serverResult = Invoke-VmShellScript -VmName $serverVmName -Script @'
set -euo pipefail
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  firewall-cmd --add-port=5201/tcp
  firewall-cmd --add-port=5201/udp
fi
pkill -f 'iperf3 -s' 2>/dev/null || true
iperf3 -s --daemon --port 5201
sleep 2
pgrep -f 'iperf3 -s' >/dev/null
echo IPERF_SERVER_STARTED
'@

if ($serverResult.Stdout -notmatch 'IPERF_SERVER_STARTED') {
  throw "Could not start iperf3 on the WireGuard server. stdout: $($serverResult.Stdout) stderr: $($serverResult.Stderr)"
}

try {
  $clientScript = @'
set -euo pipefail
TARGET=__TARGET_IP__
ROUTE=$(ip route get "$TARGET")
if [ "__PATH_MODE__" = "WireGuard" ]; then
  echo "$ROUTE" | grep -q 'dev wg0' || {
    echo "Traffic to $TARGET is not routed through wg0: $ROUTE" >&2
    exit 1
  }
elif echo "$ROUTE" | grep -q 'dev wg0'; then
  echo "Direct traffic to $TARGET unexpectedly uses wg0: $ROUTE" >&2
  exit 1
fi

ping -c 3 -W 3 "$TARGET" >/dev/null
TCP_REPORT=/tmp/wireguard-iperf-tcp.json
UDP_REPORT=/tmp/wireguard-iperf-udp.json
iperf3 -c "$TARGET" -p 5201 -P __STREAMS__ -t __DURATION__ --json >"$TCP_REPORT"
iperf3 -c "$TARGET" -p 5201 -u -b __UDP_RATE__M -l 1200 -t __DURATION__ --json >"$UDP_REPORT"

python3 - "$TCP_REPORT" "$UDP_REPORT" "$ROUTE" <<'PYEOF'
import json
import sys

with open(sys.argv[1]) as handle:
    tcp_report = json.load(handle)
with open(sys.argv[2]) as handle:
    udp_report = json.load(handle)

if tcp_report.get("error"):
    raise RuntimeError("TCP: " + tcp_report["error"])
if udp_report.get("error"):
    raise RuntimeError("UDP: " + udp_report["error"])

tcp_sent = tcp_report["end"]["sum_sent"]
tcp_received = tcp_report["end"]["sum_received"]
udp_end = udp_report["end"]
udp_sent = udp_end.get("sum_sent") or udp_end["sum"]
udp_received = udp_end.get("sum_received") or udp_end["sum"]
print(json.dumps({
    "route": sys.argv[3],
    "tcp": {
        "seconds": tcp_sent["seconds"],
        "bits_per_second_sent": tcp_sent["bits_per_second"],
        "bits_per_second_received": tcp_received["bits_per_second"],
        "retransmits": tcp_sent.get("retransmits", 0),
    },
    "udp": {
        "seconds": udp_received["seconds"],
        "bits_per_second_sent": udp_sent["bits_per_second"],
        "bits_per_second_received": udp_received["bits_per_second"],
        "jitter_ms": udp_received.get("jitter_ms", 0),
        "lost_packets": udp_received.get("lost_packets", 0),
        "packets": udp_received.get("packets", 0),
        "lost_percent": udp_received.get("lost_percent", 0),
    },
}, separators=(",", ":")))
PYEOF
'@ -replace '__TARGET_IP__', $targetIp `
     -replace '__PATH_MODE__', $Path `
     -replace '__STREAMS__', $ParallelConnections `
     -replace '__UDP_RATE__', $UdpTargetMbps `
     -replace '__DURATION__', $DurationSeconds

  $clientResult = Invoke-VmShellScript -VmName $clientVmName -Script $clientScript

  try {
    $result = $clientResult.Stdout | ConvertFrom-Json
  }
  catch {
    throw "Could not parse throughput output. stdout: $($clientResult.Stdout) stderr: $($clientResult.Stderr)"
  }

  Write-Host ''
  Write-Host "===================== $Path throughput =====================" -ForegroundColor Cyan
  Write-Host "  client       : $clientVmName"
  Write-Host "  server       : $serverVmName ($targetIp)"
  Write-Host "  route        : $($result.route)" -ForegroundColor Green
  Write-Host ''
  Write-Host '  TCP'
  Write-Host ("    duration    : {0:N1} seconds" -f $result.tcp.seconds)
  Write-Host ("    sent        : {0:N2} Gbits/sec" -f ($result.tcp.bits_per_second_sent / 1e9)) -ForegroundColor Green
  Write-Host ("    received    : {0:N2} Gbits/sec" -f ($result.tcp.bits_per_second_received / 1e9)) -ForegroundColor Green
  Write-Host ("    retransmits : {0:N0}" -f $result.tcp.retransmits)
  Write-Host ''
  Write-Host "  UDP (target $UdpTargetMbps Mbits/sec)"
  Write-Host ("    duration    : {0:N1} seconds" -f $result.udp.seconds)
  Write-Host ("    sent        : {0:N2} Gbits/sec" -f ($result.udp.bits_per_second_sent / 1e9)) -ForegroundColor Green
  Write-Host ("    received    : {0:N2} Gbits/sec" -f ($result.udp.bits_per_second_received / 1e9)) -ForegroundColor Green
  Write-Host ("    packet loss : {0:N2}% ({1:N0}/{2:N0})" -f $result.udp.lost_percent, $result.udp.lost_packets, $result.udp.packets)
  Write-Host ("    jitter      : {0:N3} ms" -f $result.udp.jitter_ms)
  Write-Host '============================================================' -ForegroundColor Cyan
}
finally {
  try {
    Invoke-VmShellScript -VmName $serverVmName -Script "pkill -f 'iperf3 -s' 2>/dev/null || true; echo stopped" | Out-Null
  }
  catch {
    Write-Warning "Could not stop iperf3 on '$serverVmName': $($_.Exception.Message)"
  }
}
