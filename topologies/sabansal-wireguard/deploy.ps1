[CmdletBinding()]
param(
  [string] $ResourceGroupName = 'sabansal-wireguard-rg',

  [string] $Location = 'westus3',

  [ValidateSet('', '1', '2', '3')]
  [string] $AvailabilityZone = '',

  [string] $SshPublicKeyPath = '~\.ssh\id_ed25519.pub',

  [switch] $OptimizeThroughput,

  [ValidateSet('WireGuard', 'Quiche')]
  [string] $Transport = 'WireGuard',

  [switch] $QuicheBusyPolling,

  [switch] $SkipThroughputTest
)

$ErrorActionPreference = 'Stop'
$deploymentName = 'sabansal-wireguard'
if ($QuicheBusyPolling -and $Transport -ne 'Quiche') {
  throw '-QuicheBusyPolling requires -Transport Quiche.'
}

function Invoke-VmShellScript {
  param(
    [Parameter(Mandatory)] [string] $VmName,
    [Parameter(Mandatory)] [string] $Script
  )

  $scriptFile = Join-Path ([System.IO.Path]::GetTempPath()) ("wireguard-{0}.sh" -f [guid]::NewGuid())
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

$resolvedKeyPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SshPublicKeyPath)
if (-not (Test-Path -LiteralPath $resolvedKeyPath -PathType Leaf)) {
  throw "SSH public key file was not found: $resolvedKeyPath"
}

$publicKey = (Get-Content -LiteralPath $resolvedKeyPath -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($publicKey)) {
  throw "SSH public key file is empty: $resolvedKeyPath"
}

az group create `
  --name $ResourceGroupName `
  --location $Location `
  --output none

if ($LASTEXITCODE -ne 0) {
  throw "Resource group creation failed with exit code $LASTEXITCODE."
}

Write-Host "Deploying two Standard_D2als_v7 Azure Linux VMs in $Location..."

az deployment group create `
  --resource-group $ResourceGroupName `
  --name $deploymentName `
  --template-file "$PSScriptRoot\main.bicep" `
  --parameters "$PSScriptRoot\main.bicepparam" `
  --parameters "location=$Location" "availabilityZone=$AvailabilityZone" `
    "optimizeThroughput=$($OptimizeThroughput.IsPresent.ToString().ToLowerInvariant())" `
    "quicheBusyPolling=$($QuicheBusyPolling.IsPresent.ToString().ToLowerInvariant())" "transport=$Transport" "adminPublicKey=$publicKey" `
  --output none

if ($LASTEXITCODE -ne 0) {
  throw "Azure deployment failed with exit code $LASTEXITCODE."
}

$outputsJson = az deployment group show `
  --resource-group $ResourceGroupName `
  --name $deploymentName `
  --query properties.outputs `
  --output json

if ($LASTEXITCODE -ne 0 -or -not $outputsJson) {
  throw 'Could not read deployment outputs.'
}

$outputs = $outputsJson | ConvertFrom-Json
$serverVmName = $outputs.serverVmName.value
$clientVmName = $outputs.clientVmName.value
$serverPrivateIp = $outputs.serverPrivateIp.value
$serverTunnelIp = $outputs.serverTunnelIp.value
$clientTunnelIp = $outputs.clientTunnelIp.value

if ($Transport -eq 'Quiche') {
  $quicheParameters = @{
    ResourceGroupName = $ResourceGroupName
    DeploymentName = $deploymentName
    KeepServerRunning = $true
    DisablePacing = $OptimizeThroughput.IsPresent
  }
  if ($SkipThroughputTest) {
    $quicheParameters.SetupOnly = $true
  }
  & "$PSScriptRoot\test-quiche-throughput.ps1" @quicheParameters
  Write-Host "quiche client/server ready: $clientVmName -> $serverVmName ($serverPrivateIp); WireGuard is stopped." -ForegroundColor Green
  return
}

$serverKeyResult = Invoke-VmShellScript -VmName $serverVmName -Script 'cat /etc/wireguard/publickey'
$clientKeyResult = Invoke-VmShellScript -VmName $clientVmName -Script 'cat /etc/wireguard/publickey'

if ($serverKeyResult.Stderr -or [string]::IsNullOrWhiteSpace($serverKeyResult.Stdout)) {
  throw "Could not retrieve the server WireGuard public key: $($serverKeyResult.Stderr)"
}
if ($clientKeyResult.Stderr -or [string]::IsNullOrWhiteSpace($clientKeyResult.Stdout)) {
  throw "Could not retrieve the client WireGuard public key: $($clientKeyResult.Stderr)"
}

$serverConfigScript = @'
set -euo pipefail
PRIVATE_KEY=$(cat /etc/wireguard/privatekey)
cat >/etc/wireguard/wg0.conf <<EOF
[Interface]
Address = __SERVER_TUNNEL_IP__/24
MTU = 1440
__TUNING_POSTUP__
ListenPort = 51820
PrivateKey = ${PRIVATE_KEY}

[Peer]
PublicKey = __CLIENT_PUBLIC_KEY__
AllowedIPs = __CLIENT_TUNNEL_IP__/32
EOF
chmod 600 /etc/wireguard/wg0.conf
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0
__TUNING_AFFINITY_CHECK__
wg show wg0
echo WIREGUARD_SERVER_CONFIGURED
'@ -replace '__TUNING_POSTUP__', $(if ($OptimizeThroughput) { 'PostUp = /usr/local/sbin/configure-wireguard-throughput --tunnel-only' } else { '' }) `
   -replace '__TUNING_AFFINITY_CHECK__', $(if ($OptimizeThroughput) { 'systemctl start wireguard-receive-affinity.service' } else { '' }) `
   -replace '__SERVER_TUNNEL_IP__', $serverTunnelIp `
   -replace '__CLIENT_TUNNEL_IP__', $clientTunnelIp `
   -replace '__CLIENT_PUBLIC_KEY__', $clientKeyResult.Stdout.Trim()

$clientConfigScript = @'
set -euo pipefail
PRIVATE_KEY=$(cat /etc/wireguard/privatekey)
cat >/etc/wireguard/wg0.conf <<EOF
[Interface]
Address = __CLIENT_TUNNEL_IP__/24
MTU = 1440
__TUNING_POSTUP__
PrivateKey = ${PRIVATE_KEY}

[Peer]
PublicKey = __SERVER_PUBLIC_KEY__
Endpoint = __SERVER_PRIVATE_IP__:51820
AllowedIPs = __SERVER_TUNNEL_IP__/32
PersistentKeepalive = 25
EOF
chmod 600 /etc/wireguard/wg0.conf
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0
__TUNING_AFFINITY_CHECK__
ping -c 3 -W 3 __SERVER_TUNNEL_IP__
wg show wg0
echo WIREGUARD_CLIENT_CONFIGURED
'@ -replace '__TUNING_POSTUP__', $(if ($OptimizeThroughput) { 'PostUp = /usr/local/sbin/configure-wireguard-throughput --tunnel-only' } else { '' }) `
   -replace '__TUNING_AFFINITY_CHECK__', $(if ($OptimizeThroughput) { 'systemctl start wireguard-receive-affinity.service' } else { '' }) `
   -replace '__CLIENT_TUNNEL_IP__', $clientTunnelIp `
   -replace '__SERVER_TUNNEL_IP__', $serverTunnelIp `
   -replace '__SERVER_PRIVATE_IP__', $serverPrivateIp `
   -replace '__SERVER_PUBLIC_KEY__', $serverKeyResult.Stdout.Trim()

$serverConfigResult = Invoke-VmShellScript -VmName $serverVmName -Script $serverConfigScript
if ($serverConfigResult.Stdout -notmatch 'WIREGUARD_SERVER_CONFIGURED') {
  throw "WireGuard server configuration failed. stdout: $($serverConfigResult.Stdout) stderr: $($serverConfigResult.Stderr)"
}

$clientConfigResult = Invoke-VmShellScript -VmName $clientVmName -Script $clientConfigScript
if ($clientConfigResult.Stdout -notmatch 'WIREGUARD_CLIENT_CONFIGURED') {
  throw "WireGuard client configuration failed. stdout: $($clientConfigResult.Stdout) stderr: $($clientConfigResult.Stderr)"
}

Write-Host ''
Write-Host "WireGuard connected: $clientVmName ($clientTunnelIp) -> $serverVmName ($serverTunnelIp)" -ForegroundColor Green

if (-not $SkipThroughputTest) {
  Write-Host ''
  & "$PSScriptRoot\test-throughput.ps1" `
    -ResourceGroupName $ResourceGroupName `
    -DeploymentName $deploymentName

  if ($LASTEXITCODE -ne 0) {
    throw "WireGuard throughput test failed with exit code $LASTEXITCODE."
  }
}
