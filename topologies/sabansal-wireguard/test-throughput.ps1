[CmdletBinding()]
param(
  [string] $ResourceGroupName = 'sabansal-wireguard-rg',

  [string] $DeploymentName = 'sabansal-wireguard',

  [ValidateSet('WireGuard', 'Direct')]
  [string] $Path = 'WireGuard',

  [switch] $Reverse,

  [string] $OutputPath,

  [ValidateRange(1, 32)]
  [int] $ParallelConnections = 8,

  [ValidateRange(0, 100000)]
  [int] $UdpTargetMbps = 0,

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
$udpAutoPercent = if ($Path -eq 'WireGuard') { 105 } else { 60 }

$serverScript = @'
set -euo pipefail
IPERF=$(command -v iperf3)
"$IPERF" --help 2>&1 | grep -q -- '--gsro' || {
  echo "iperf3 does not support --gsro; deploy the topology again to install the pinned GSO-enabled build." >&2
  exit 1
}
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  firewall-cmd --add-port=5201/tcp
  firewall-cmd --add-port=5201/udp
fi
systemd-run --collect --unit=wireguard-throughput-iperf "$IPERF" -s --port 5201
sleep 2
systemctl is-active --quiet wireguard-throughput-iperf
echo IPERF_SERVER_STARTED
'@

$serverResult = Invoke-VmShellScript -VmName $serverVmName -Script $serverScript

if ($serverResult.Stdout -notmatch 'IPERF_SERVER_STARTED') {
  throw "Could not start iperf3 on the WireGuard server. stdout: $($serverResult.Stdout) stderr: $($serverResult.Stderr)"
}

try {
  $clientScript = @'
set -euo pipefail
TARGET=__TARGET_IP__
IPERF=$(command -v iperf3)
"$IPERF" --help 2>&1 | grep -q -- '--gsro' || {
  echo "iperf3 does not support --gsro; deploy the topology again to install the pinned GSO-enabled build." >&2
  exit 1
}
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
read -r _ tcp_cpu_user tcp_cpu_nice tcp_cpu_system tcp_cpu_idle tcp_cpu_iowait tcp_cpu_irq tcp_cpu_softirq tcp_cpu_steal _ </proc/stat
TCP_CPU_TOTAL_BEFORE=$((tcp_cpu_user + tcp_cpu_nice + tcp_cpu_system + tcp_cpu_idle + tcp_cpu_iowait + tcp_cpu_irq + tcp_cpu_softirq + tcp_cpu_steal))
TCP_CPU_IDLE_BEFORE=$((tcp_cpu_idle + tcp_cpu_iowait))
"$IPERF" -c "$TARGET" -p 5201 -P __STREAMS__ -w 4M -Z -t __DURATION__ __REVERSE__ --json >"$TCP_REPORT"
read -r _ tcp_cpu_user tcp_cpu_nice tcp_cpu_system tcp_cpu_idle tcp_cpu_iowait tcp_cpu_irq tcp_cpu_softirq tcp_cpu_steal _ </proc/stat
TCP_CPU_TOTAL_AFTER=$((tcp_cpu_user + tcp_cpu_nice + tcp_cpu_system + tcp_cpu_idle + tcp_cpu_iowait + tcp_cpu_irq + tcp_cpu_softirq + tcp_cpu_steal))
TCP_CPU_IDLE_AFTER=$((tcp_cpu_idle + tcp_cpu_iowait))

UDP_TARGET_MBPS=__UDP_RATE__
if [ "$UDP_TARGET_MBPS" -eq 0 ]; then
  UDP_TARGET_MBPS=$(python3 - "$TCP_REPORT" <<'PYEOF'
import json
import sys

with open(sys.argv[1]) as handle:
    report = json.load(handle)

received_bps = report["end"]["sum_received"]["bits_per_second"]
print(max(1, int(received_bps * __UDP_AUTO_PERCENT__ / 100 / 1_000_000)))
PYEOF
)
fi

VCPU_COUNT=$(nproc)
UDP_STREAMS=$VCPU_COUNT
if [ "$UDP_STREAMS" -gt __STREAMS__ ]; then
  UDP_STREAMS=__STREAMS__
fi
run_udp() {
  local target_mbps=$1
  local duration=$2
  local report=$3
  local stream_rate_mbps=$(( (target_mbps + UDP_STREAMS - 1) / UDP_STREAMS ))
  "$IPERF" -c "$TARGET" -p 5201 -u -P "$UDP_STREAMS" -b "${stream_rate_mbps}M" \
    -l __UDP_DATAGRAM_BYTES__ -t "$duration" __REVERSE__ --gsro --json >"$report"
}

UDP_STREAM_RATE_MBPS=$(( (UDP_TARGET_MBPS + UDP_STREAMS - 1) / UDP_STREAMS ))
UDP_EFFECTIVE_TARGET_MBPS=$(( UDP_STREAM_RATE_MBPS * UDP_STREAMS ))
read -r _ cpu_user cpu_nice cpu_system cpu_idle cpu_iowait cpu_irq cpu_softirq cpu_steal _ </proc/stat
CPU_TOTAL_BEFORE=$((cpu_user + cpu_nice + cpu_system + cpu_idle + cpu_iowait + cpu_irq + cpu_softirq + cpu_steal))
CPU_IDLE_BEFORE=$((cpu_idle + cpu_iowait))
run_udp "$UDP_TARGET_MBPS" __DURATION__ "$UDP_REPORT"
read -r _ cpu_user cpu_nice cpu_system cpu_idle cpu_iowait cpu_irq cpu_softirq cpu_steal _ </proc/stat
CPU_TOTAL_AFTER=$((cpu_user + cpu_nice + cpu_system + cpu_idle + cpu_iowait + cpu_irq + cpu_softirq + cpu_steal))
CPU_IDLE_AFTER=$((cpu_idle + cpu_iowait))

python3 - "$TCP_REPORT" "$UDP_REPORT" "$ROUTE" "$UDP_EFFECTIVE_TARGET_MBPS" "$UDP_STREAMS" "$VCPU_COUNT" \
  "$CPU_TOTAL_BEFORE" "$CPU_IDLE_BEFORE" "$CPU_TOTAL_AFTER" "$CPU_IDLE_AFTER" \
  "$TCP_CPU_TOTAL_BEFORE" "$TCP_CPU_IDLE_BEFORE" "$TCP_CPU_TOTAL_AFTER" "$TCP_CPU_IDLE_AFTER" <<'PYEOF'
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
tcp_cpu = tcp_report["end"].get("cpu_utilization_percent", {})
udp_end = udp_report["end"]
udp_sent = udp_end.get("sum_sent") or udp_end["sum"]
udp_received = udp_end.get("sum_received") or udp_end["sum"]
if tcp_received["bits_per_second"] <= 0 or udp_received["bits_per_second"] <= 0:
    raise RuntimeError("Benchmark completed without receiving traffic")
udp_cpu = udp_end.get("cpu_utilization_percent", {})
udp_streams = int(sys.argv[5])
vcpu_count = int(sys.argv[6])
cpu_total_delta = int(sys.argv[9]) - int(sys.argv[7])
cpu_idle_delta = int(sys.argv[10]) - int(sys.argv[8])
client_vm_cpu = 100.0 * (cpu_total_delta - cpu_idle_delta) / cpu_total_delta
tcp_cpu_total_delta = int(sys.argv[13]) - int(sys.argv[11])
tcp_cpu_idle_delta = int(sys.argv[14]) - int(sys.argv[12])
tcp_client_vm_cpu = 100.0 * (tcp_cpu_total_delta - tcp_cpu_idle_delta) / tcp_cpu_total_delta

print(json.dumps({
    "route": sys.argv[3],
    "tcp": {
        "seconds": tcp_sent["seconds"],
        "bits_per_second_sent": tcp_sent["bits_per_second"],
        "bits_per_second_received": tcp_received["bits_per_second"],
        "retransmits": tcp_sent.get("retransmits", 0),
        "client_cpu_percent": tcp_cpu.get("host_total", 0) / vcpu_count,
        "server_cpu_percent": tcp_cpu.get("remote_total", 0) / vcpu_count,
        "client_vm_cpu_percent": tcp_client_vm_cpu,
    },
    "udp": {
        "target_mbps": int(sys.argv[4]),
        "datagram_bytes": __UDP_DATAGRAM_BYTES__,
        "offload": "GSO/GRO",
        "streams": udp_streams,
        "seconds": udp_received["seconds"],
        "bits_per_second_sent": udp_sent["bits_per_second"],
        "bits_per_second_received": udp_received["bits_per_second"],
        "jitter_ms": udp_received.get("jitter_ms", 0),
        "lost_packets": udp_received.get("lost_packets", 0),
        "packets": udp_received.get("packets", 0),
        "lost_percent": udp_received.get("lost_percent", 0),
        "client_cpu_percent": udp_cpu.get("host_total", 0) / vcpu_count,
        "server_cpu_percent": udp_cpu.get("remote_total", 0) / vcpu_count,
        "client_vm_cpu_percent": client_vm_cpu,
    },
}, separators=(",", ":")))
PYEOF
'@ -replace '__TARGET_IP__', $targetIp `
     -replace '__PATH_MODE__', $Path `
     -replace '__STREAMS__', $ParallelConnections `
     -replace '__UDP_RATE__', $UdpTargetMbps `
     -replace '__UDP_AUTO_PERCENT__', $udpAutoPercent `
     -replace '__UDP_DATAGRAM_BYTES__', $UdpDatagramBytes `
     -replace '__DURATION__', $DurationSeconds
  $clientScript = $clientScript -replace '__REVERSE__', $(if ($Reverse) { '-R' } else { '' })

  $clientResult = Invoke-VmShellScript -VmName $clientVmName -Script $clientScript

  try {
    $result = $clientResult.Stdout | ConvertFrom-Json
  }
  catch {
    throw "Could not parse throughput output. stdout: $($clientResult.Stdout) stderr: $($clientResult.Stderr)"
  }

  if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    [pscustomobject]@{
      timestampUtc = [DateTime]::UtcNow.ToString('o')
      resourceGroup = $ResourceGroupName
      path = $Path
      reverse = $Reverse.IsPresent
      parallelConnections = $ParallelConnections
      result = $result
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputPath -Encoding utf8
  }

  Write-Host ''
  Write-Host "===================== $Path throughput =====================" -ForegroundColor Cyan
  Write-Host "  client       : $clientVmName"
  Write-Host "  server       : $serverVmName ($targetIp)"
  Write-Host "  route        : $($result.route)" -ForegroundColor Green
  Write-Host "  direction    : $(if ($Reverse) { 'server -> client' } else { 'client -> server' })"
  Write-Host ''
  Write-Host '  TCP'
  Write-Host ("    duration    : {0:N1} seconds" -f $result.tcp.seconds)
  Write-Host ("    sent        : {0:N2} Gbits/sec" -f ($result.tcp.bits_per_second_sent / 1e9)) -ForegroundColor Green
  Write-Host ("    received    : {0:N2} Gbits/sec" -f ($result.tcp.bits_per_second_received / 1e9)) -ForegroundColor Green
  Write-Host ("    retransmits : {0:N0}" -f $result.tcp.retransmits)
  Write-Host ("    client VM CPU    : {0:N1}%" -f $result.tcp.client_vm_cpu_percent)
  Write-Host ("    client iperf CPU : {0:N1}%" -f $result.tcp.client_cpu_percent)
  Write-Host ("    server iperf CPU : {0:N1}%" -f $result.tcp.server_cpu_percent)
  Write-Host ''
  Write-Host ("  UDP (target {0:N0} Mbits/sec, {1})" -f $result.udp.target_mbps, $result.udp.offload)
  Write-Host ("    streams     : {0:N0}" -f $result.udp.streams)
  Write-Host ("    datagram    : {0:N0} bytes" -f $result.udp.datagram_bytes)
  Write-Host ("    duration    : {0:N1} seconds" -f $result.udp.seconds)
  Write-Host ("    sent        : {0:N2} Gbits/sec" -f ($result.udp.bits_per_second_sent / 1e9)) -ForegroundColor Green
  Write-Host ("    received    : {0:N2} Gbits/sec" -f ($result.udp.bits_per_second_received / 1e9)) -ForegroundColor Green
  Write-Host ("    packet loss : {0:N2}% ({1:N0}/{2:N0})" -f $result.udp.lost_percent, $result.udp.lost_packets, $result.udp.packets)
  Write-Host ("    jitter      : {0:N3} ms" -f $result.udp.jitter_ms)
  Write-Host ("    client VM CPU    : {0:N1}%" -f $result.udp.client_vm_cpu_percent)
  Write-Host ("    client iperf CPU : {0:N1}%" -f $result.udp.client_cpu_percent)
  Write-Host ("    server iperf CPU : {0:N1}%" -f $result.udp.server_cpu_percent)
  Write-Host '============================================================' -ForegroundColor Cyan
}
finally {
  try {
    $stopResult = Invoke-VmShellScript -VmName $serverVmName -Script 'set -e; systemctl stop wireguard-throughput-iperf; echo IPERF_SERVER_STOPPED'
    if ($stopResult.Stdout -notmatch 'IPERF_SERVER_STOPPED') {
      throw "Server cleanup failed. stdout: $($stopResult.Stdout) stderr: $($stopResult.Stderr)"
    }
  }
  catch {
    Write-Warning "Could not stop iperf3 on '$serverVmName': $($_.Exception.Message)"
  }
}
