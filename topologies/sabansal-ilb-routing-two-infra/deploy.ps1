[CmdletBinding()]
param(
  [string] $ResourceGroupName = 'sabansal-ilb-routing-two-infra-rg',

  [string] $Location = 'westus3',

  [string] $SshPublicKeyPath = '~\.ssh\id_ed25519.pub',

  [string] $VmSize = 'Standard_D2als_v7',

  [switch] $SkipThroughputTest,

  [ValidateRange(1, 100000)]
  [int] $UdpTargetMbps = 5000,

  [ValidateRange(5, 600)]
  [int] $DurationSeconds = 30
)

$ErrorActionPreference = 'Stop'
$deploymentName = 'sabansal-ilb-routing-two-infra'

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

Write-Host "Deploying two infra VMs with one secondary routing IP behind the HA-ports ILB..."

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
    -UdpTargetMbps $UdpTargetMbps `
    -DurationSeconds $DurationSeconds
}
