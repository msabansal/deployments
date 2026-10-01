[CmdletBinding()]
param(
  [string] $ResourceGroupName = 'sabansal-wireguard-rg',

  [string] $DeploymentName = 'sabansal-wireguard',

  [ValidateRange(1, 32)]
  [int] $ParallelConnections = 8,

  [ValidateRange(5, 600)]
  [int] $DurationSeconds = 30
)

$ErrorActionPreference = 'Stop'

function Invoke-VmShellScript {
  param(
    [Parameter(Mandatory)] [string] $VmName,
    [Parameter(Mandatory)] [string] $Script
  )

  $scriptFile = Join-Path ([System.IO.Path]::GetTempPath()) ("tls-tcp-test-{0}.sh" -f [guid]::NewGuid())
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
$serverPrivateIp = $outputs.serverPrivateIp.value

$sourcePath = Join-Path $PSScriptRoot 'tls-tcp-benchmark\main.go'
$source = Get-Content -LiteralPath $sourcePath -Raw
$sourceBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($source -replace "`r`n", "`n")))

$installScript = @'
set -euo pipefail
if ! command -v go >/dev/null 2>&1; then
  if command -v tdnf >/dev/null 2>&1; then
    tdnf install -y golang
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y golang
  else
    echo "No supported package manager found" >&2
    exit 1
  fi
fi
install -d /opt/tls-tcp-benchmark
printf '%s' '__SOURCE_BASE64__' | base64 -d >/opt/tls-tcp-benchmark/main.go
cd /opt/tls-tcp-benchmark
export HOME=/root
export GOPATH=/root/go
GOTOOLCHAIN=local go build -trimpath -o /usr/local/bin/tls-tcp-benchmark ./main.go
echo TLS_TCP_BENCHMARK_INSTALLED
'@ -replace '__SOURCE_BASE64__', $sourceBase64

foreach ($vmName in @($serverVmName, $clientVmName)) {
  $installResult = Invoke-VmShellScript -VmName $vmName -Script $installScript
  if ($installResult.Stdout -notmatch 'TLS_TCP_BENCHMARK_INSTALLED') {
    throw "Could not install the TLS/TCP benchmark on '$vmName'. stdout: $($installResult.Stdout) stderr: $($installResult.Stderr)"
  }
}

$serverScript = @'
set -euo pipefail
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  firewall-cmd --add-port=4434/tcp
fi
rm -f /tmp/tls-tcp-benchmark-result.json
cat >/etc/systemd/system/tls-tcp-benchmark.service <<'EOF'
[Unit]
Description=Raw TLS 1.3 over TCP throughput benchmark server
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/tls-tcp-benchmark -mode server -listen 0.0.0.0:4434 -parallel __PARALLEL__ -duration __DURATION__s -result /tmp/tls-tcp-benchmark-result.json
Restart=no
LimitNOFILE=1048576
EOF
systemctl daemon-reload
systemctl restart tls-tcp-benchmark
for attempt in $(seq 1 20); do
  if systemctl is-active --quiet tls-tcp-benchmark && ss -ltn | grep -q ':4434 '; then
    echo TLS_TCP_SERVER_STARTED
    exit 0
  fi
  sleep 1
done
systemctl status tls-tcp-benchmark --no-pager >&2 || true
journalctl -u tls-tcp-benchmark -n 50 --no-pager >&2 || true
exit 1
'@ -replace '__PARALLEL__', $ParallelConnections `
   -replace '__DURATION__', $DurationSeconds

$serverResult = Invoke-VmShellScript -VmName $serverVmName -Script $serverScript
if ($serverResult.Stdout -notmatch 'TLS_TCP_SERVER_STARTED') {
  throw "Could not start TLS/TCP on '$serverVmName'. stdout: $($serverResult.Stdout) stderr: $($serverResult.Stderr)"
}

try {
  $clientScript = @'
set -euo pipefail
TARGET=__TARGET_IP__
ROUTE=$(ip route get "$TARGET")
if echo "$ROUTE" | grep -q 'dev wg0'; then
  echo "Direct traffic to $TARGET unexpectedly uses wg0: $ROUTE" >&2
  exit 1
fi
ping -c 3 -W 3 "$TARGET" >/dev/null
RESULT=$(/usr/local/bin/tls-tcp-benchmark \
  -mode client \
  -server "${TARGET}:4434" \
  -parallel __PARALLEL__ \
  -duration __DURATION__s)
echo "TLS_TCP_CLIENT_RESULT=${RESULT}"
'@ -replace '__TARGET_IP__', $serverPrivateIp `
     -replace '__PARALLEL__', $ParallelConnections `
     -replace '__DURATION__', $DurationSeconds

  $clientResult = Invoke-VmShellScript -VmName $clientVmName -Script $clientScript
  $clientResultLine = ($clientResult.Stdout -split "`n" | Where-Object { $_ -like 'TLS_TCP_CLIENT_RESULT=*' } | Select-Object -Last 1)
  if (-not $clientResultLine) {
    throw "Could not find the TLS/TCP client result. stdout: $($clientResult.Stdout) stderr: $($clientResult.Stderr)"
  }
  $clientMetrics = $clientResultLine.Substring('TLS_TCP_CLIENT_RESULT='.Length) | ConvertFrom-Json

  $serverMetricsScript = @'
set -euo pipefail
for attempt in $(seq 1 20); do
  if [ -s /tmp/tls-tcp-benchmark-result.json ]; then
    echo "TLS_TCP_SERVER_RESULT=$(cat /tmp/tls-tcp-benchmark-result.json)"
    exit 0
  fi
  sleep 1
done
systemctl status tls-tcp-benchmark --no-pager >&2 || true
journalctl -u tls-tcp-benchmark -n 50 --no-pager >&2 || true
exit 1
'@
  $serverMetricsResult = Invoke-VmShellScript -VmName $serverVmName -Script $serverMetricsScript
  $serverResultLine = ($serverMetricsResult.Stdout -split "`n" | Where-Object { $_ -like 'TLS_TCP_SERVER_RESULT=*' } | Select-Object -Last 1)
  if (-not $serverResultLine) {
    throw "Could not find the TLS/TCP server result. stdout: $($serverMetricsResult.Stdout) stderr: $($serverMetricsResult.Stderr)"
  }
  $serverMetrics = $serverResultLine.Substring('TLS_TCP_SERVER_RESULT='.Length) | ConvertFrom-Json

  Write-Host ''
  Write-Host '===================== Direct TLS/TCP throughput =====================' -ForegroundColor Cyan
  Write-Host "  client            : $clientVmName"
  Write-Host "  server            : $serverVmName ($serverPrivateIp)"
  Write-Host "  protocol          : $($clientMetrics.protocol)"
  Write-Host "  cipher            : $($clientMetrics.tls_cipher_suite)"
  Write-Host "  parallel streams  : $($clientMetrics.parallel_streams)"
  Write-Host ("  duration          : {0:N1} seconds" -f $clientMetrics.duration_seconds)
  Write-Host ("  received          : {0:N2} Gbits/sec" -f ($clientMetrics.bits_per_second / 1e9)) -ForegroundColor Green
  Write-Host ("  client VM CPU     : {0:N1}%" -f $clientMetrics.vm_cpu_percent)
  Write-Host ("  server VM CPU     : {0:N1}%" -f $serverMetrics.vm_cpu_percent)
  Write-Host ("  transferred       : {0:N2} GiB" -f ($clientMetrics.bytes_transferred / 1GB))
  Write-Host '=====================================================================' -ForegroundColor Cyan
}
finally {
  try {
    Invoke-VmShellScript -VmName $serverVmName -Script 'systemctl stop tls-tcp-benchmark 2>/dev/null || true; echo TLS_TCP_SERVER_STOPPED' | Out-Null
  }
  catch {
    Write-Warning "Could not stop TLS/TCP on '$serverVmName': $($_.Exception.Message)"
  }
}
