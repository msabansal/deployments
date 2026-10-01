[CmdletBinding()]
param(
  [string] $ResourceGroupName = 'sabansal-wireguard-rg',

  [string] $DeploymentName = 'sabansal-wireguard',

  [ValidateRange(1, 32)]
  [int] $ParallelConnections = 4,

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

$serverResult = Invoke-VmShellScript -VmName $serverVmName -Script @'
set -euo pipefail
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
TARGET=__SERVER_TUNNEL_IP__
ROUTE=$(ip route get "$TARGET")
echo "$ROUTE" | grep -q 'dev wg0' || {
  echo "Traffic to $TARGET is not routed through wg0: $ROUTE" >&2
  exit 1
}

ping -c 3 -W 3 "$TARGET" >/dev/null
REPORT=/tmp/wireguard-iperf.json
iperf3 -c "$TARGET" -p 5201 -P __STREAMS__ -t __DURATION__ --json >"$REPORT"

python3 - "$REPORT" "$ROUTE" <<'PYEOF'
import json
import sys

with open(sys.argv[1]) as handle:
    report = json.load(handle)

if report.get("error"):
    raise RuntimeError(report["error"])

sent = report["end"]["sum_sent"]
received = report["end"]["sum_received"]
print(json.dumps({
    "route": sys.argv[2],
    "seconds": sent["seconds"],
    "bytes": sent["bytes"],
    "bits_per_second_sent": sent["bits_per_second"],
    "bits_per_second_received": received["bits_per_second"],
    "retransmits": sent.get("retransmits", 0),
}, separators=(",", ":")))
PYEOF
'@ -replace '__SERVER_TUNNEL_IP__', $serverTunnelIp `
     -replace '__STREAMS__', $ParallelConnections `
     -replace '__DURATION__', $DurationSeconds

  $clientResult = Invoke-VmShellScript -VmName $clientVmName -Script $clientScript

  try {
    $result = $clientResult.Stdout | ConvertFrom-Json
  }
  catch {
    throw "Could not parse throughput output. stdout: $($clientResult.Stdout) stderr: $($clientResult.Stderr)"
  }

  Write-Host ''
  Write-Host '============== WireGuard throughput ==============' -ForegroundColor Cyan
  Write-Host "  client       : $clientVmName"
  Write-Host "  server       : $serverVmName ($serverTunnelIp)"
  Write-Host "  route        : $($result.route)" -ForegroundColor Green
  Write-Host ("  duration     : {0:N1} seconds" -f $result.seconds)
  Write-Host ("  sent         : {0:N2} Gbits/sec" -f ($result.bits_per_second_sent / 1e9)) -ForegroundColor Green
  Write-Host ("  received     : {0:N2} Gbits/sec" -f ($result.bits_per_second_received / 1e9)) -ForegroundColor Green
  Write-Host ("  retransmits  : {0:N0}" -f $result.retransmits)
  Write-Host '==================================================' -ForegroundColor Cyan
}
finally {
  try {
    Invoke-VmShellScript -VmName $serverVmName -Script "pkill -f 'iperf3 -s' 2>/dev/null || true; echo stopped" | Out-Null
  }
  catch {
    Write-Warning "Could not stop iperf3 on '$serverVmName': $($_.Exception.Message)"
  }
}
