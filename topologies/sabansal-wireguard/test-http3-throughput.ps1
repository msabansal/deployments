[CmdletBinding()]
param(
  [string] $ResourceGroupName = 'sabansal-wireguard-rg',

  [string] $DeploymentName = 'sabansal-wireguard',

  [ValidateSet('WireGuard', 'Direct')]
  [string] $Path = 'Direct',

  [ValidateRange(1, 32)]
  [int] $ParallelRequests = 8,

  [ValidateRange(5, 600)]
  [int] $DurationSeconds = 30
)

$ErrorActionPreference = 'Stop'

function Invoke-VmShellScript {
  param(
    [Parameter(Mandatory)] [string] $VmName,
    [Parameter(Mandatory)] [string] $Script
  )

  $scriptFile = Join-Path ([System.IO.Path]::GetTempPath()) ("http3-test-{0}.sh" -f [guid]::NewGuid())
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

function ConvertTo-Base64 {
  param([Parameter(Mandatory)] [string] $Value)

  [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Value -replace "`r`n", "`n")))
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

$sourceDirectory = Join-Path $PSScriptRoot 'http3-benchmark'
$goModBase64 = ConvertTo-Base64 -Value (Get-Content -LiteralPath (Join-Path $sourceDirectory 'go.mod') -Raw)
$goSumBase64 = ConvertTo-Base64 -Value (Get-Content -LiteralPath (Join-Path $sourceDirectory 'go.sum') -Raw)
$mainGoBase64 = ConvertTo-Base64 -Value (Get-Content -LiteralPath (Join-Path $sourceDirectory 'main.go') -Raw)

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
install -d /opt/http3-benchmark
printf '%s' '__GO_MOD_BASE64__' | base64 -d >/opt/http3-benchmark/go.mod
printf '%s' '__GO_SUM_BASE64__' | base64 -d >/opt/http3-benchmark/go.sum
printf '%s' '__MAIN_GO_BASE64__' | base64 -d >/opt/http3-benchmark/main.go
cd /opt/http3-benchmark
export HOME=/root
export GOPATH=/root/go
GOTOOLCHAIN=local go mod download
GOTOOLCHAIN=local go build -trimpath -o /usr/local/bin/http3-benchmark .
echo HTTP3_BENCHMARK_INSTALLED
'@ -replace '__GO_MOD_BASE64__', $goModBase64 `
   -replace '__GO_SUM_BASE64__', $goSumBase64 `
   -replace '__MAIN_GO_BASE64__', $mainGoBase64

$serverInstallResult = Invoke-VmShellScript -VmName $serverVmName -Script $installScript
if ($serverInstallResult.Stdout -notmatch 'HTTP3_BENCHMARK_INSTALLED') {
  throw "Could not install the HTTP/3 benchmark on '$serverVmName'. stdout: $($serverInstallResult.Stdout) stderr: $($serverInstallResult.Stderr)"
}

$clientInstallResult = Invoke-VmShellScript -VmName $clientVmName -Script $installScript
if ($clientInstallResult.Stdout -notmatch 'HTTP3_BENCHMARK_INSTALLED') {
  throw "Could not install the HTTP/3 benchmark on '$clientVmName'. stdout: $($clientInstallResult.Stdout) stderr: $($clientInstallResult.Stderr)"
}

$serverScript = @'
set -euo pipefail
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  firewall-cmd --add-port=4433/udp
fi
cat >/etc/systemd/system/http3-benchmark.service <<'EOF'
[Unit]
Description=HTTP/3 throughput benchmark server
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/http3-benchmark -mode server -listen 0.0.0.0:4433
Restart=on-failure
RestartSec=1
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl restart http3-benchmark
for attempt in $(seq 1 20); do
  if systemctl is-active --quiet http3-benchmark && ss -lun | grep -q ':4433 '; then
    echo HTTP3_SERVER_STARTED
    exit 0
  fi
  sleep 1
done
systemctl status http3-benchmark --no-pager >&2 || true
journalctl -u http3-benchmark -n 50 --no-pager >&2 || true
exit 1
'@

$serverResult = Invoke-VmShellScript -VmName $serverVmName -Script $serverScript
if ($serverResult.Stdout -notmatch 'HTTP3_SERVER_STARTED') {
  throw "Could not start HTTP/3 on '$serverVmName'. stdout: $($serverResult.Stdout) stderr: $($serverResult.Stderr)"
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
RESULT=$(/usr/local/bin/http3-benchmark \
  -mode client \
  -url "https://${TARGET}:4433" \
  -parallel __PARALLEL__ \
  -duration __DURATION__s)
echo "HTTP3_RESULT=${RESULT}"
'@ -replace '__TARGET_IP__', $targetIp `
     -replace '__PATH_MODE__', $Path `
     -replace '__PARALLEL__', $ParallelRequests `
     -replace '__DURATION__', $DurationSeconds

  $clientResult = Invoke-VmShellScript -VmName $clientVmName -Script $clientScript
  $resultLine = ($clientResult.Stdout -split "`n" | Where-Object { $_ -like 'HTTP3_RESULT=*' } | Select-Object -Last 1)
  if (-not $resultLine) {
    throw "Could not find the HTTP/3 result. stdout: $($clientResult.Stdout) stderr: $($clientResult.Stderr)"
  }

  try {
    $result = $resultLine.Substring('HTTP3_RESULT='.Length) | ConvertFrom-Json
  }
  catch {
    throw "Could not parse the HTTP/3 result. stdout: $($clientResult.Stdout) stderr: $($clientResult.Stderr)"
  }

  Write-Host ''
  Write-Host "===================== $Path HTTP/3 throughput =====================" -ForegroundColor Cyan
  Write-Host "  client            : $clientVmName"
  Write-Host "  server            : $serverVmName ($targetIp)"
  Write-Host "  protocol          : $($result.protocol) over QUIC/UDP"
  Write-Host "  parallel requests : $($result.parallel_requests)"
  Write-Host ("  duration          : {0:N1} seconds" -f $result.duration_seconds)
  Write-Host ("  received          : {0:N2} Gbits/sec" -f ($result.bits_per_second_received / 1e9)) -ForegroundColor Green
  Write-Host ("  client VM CPU     : {0:N1}%" -f $result.client_vm_cpu_percent)
  Write-Host ("  server VM CPU     : {0:N1}%" -f $result.server_vm_cpu_percent)
  Write-Host ("  transferred       : {0:N2} GiB" -f ($result.bytes_received / 1GB))
  Write-Host '==================================================================' -ForegroundColor Cyan
}
finally {
  try {
    Invoke-VmShellScript -VmName $serverVmName -Script 'systemctl stop http3-benchmark; echo HTTP3_SERVER_STOPPED' | Out-Null
  }
  catch {
    Write-Warning "Could not stop HTTP/3 on '$serverVmName': $($_.Exception.Message)"
  }
}
