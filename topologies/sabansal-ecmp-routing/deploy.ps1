[CmdletBinding()]
param(
  [string] $ResourceGroupName = 'sabansal-ilb-routing-rg',

  [string] $Location = 'centralindia',

  [string] $SshPublicKeyPath = '~\.ssh\id_ed25519.pub',

  [string] $SshPrivateKeyPath = '~\.ssh\id_ed25519',

  [string] $VmSize = 'Standard_D2als_v6',

  [switch] $SkipThroughputTest,

  [ValidateRange(1, 100000)]
  [int] $UdpTargetMbps = 5000,

  [ValidateRange(5, 600)]
  [int] $DurationSeconds = 30
)

$ErrorActionPreference = 'Stop'
$deploymentName = 'sabansal-ecmp-routing'

$groupExists = az group exists --name $ResourceGroupName --output tsv
if ($LASTEXITCODE -ne 0 -or $groupExists -ne 'true') {
  throw "Existing resource group '$ResourceGroupName' was not found."
}

$resolvedKeyPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SshPublicKeyPath)
if (-not (Test-Path -LiteralPath $resolvedKeyPath -PathType Leaf)) {
  throw "SSH public key file was not found: $resolvedKeyPath"
}

$publicKey = (Get-Content -LiteralPath $resolvedKeyPath -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($publicKey)) {
  throw "SSH public key file is empty: $resolvedKeyPath"
}

Write-Host "Deploying Azure Linux 4 VM1 -> ECMP routers -> VM2 topology into '$ResourceGroupName'..."

az deployment group create `
  --resource-group $ResourceGroupName `
  --name $deploymentName `
  --template-file "$PSScriptRoot\main.bicep" `
  --parameters "$PSScriptRoot\main.bicepparam" `
  --parameters "location=$Location" "adminPublicKey=$publicKey" "vmSize=$VmSize" `
  --output none

if ($LASTEXITCODE -ne 0) {
  throw "Azure deployment failed with exit code $LASTEXITCODE."
}

Write-Host 'Deployment complete.' -ForegroundColor Green

if (-not $SkipThroughputTest) {
  & "$PSScriptRoot\test-throughput.ps1" `
    -ResourceGroupName $ResourceGroupName `
    -DeploymentName $deploymentName `
    -SshPrivateKeyPath $SshPrivateKeyPath `
    -UdpTargetMbps $UdpTargetMbps `
    -DurationSeconds $DurationSeconds
}
