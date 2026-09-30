[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $ResourceGroupName,

  [Parameter(Mandatory)]
  [string] $Location,

  [string] $SshPublicKeyPath = '~\.ssh\id_ed25519.pub',

  [string] $EndpointVmSize,

  [string] $RouterVmSize,

  [switch] $RunConnectivityTest,

  [ValidateRange(1, 128)]
  [int] $ParallelConnections = 8,

  [ValidateRange(5, 3600)]
  [int] $DurationSeconds = 60
)

$ErrorActionPreference = 'Stop'

$resolvedKeyPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SshPublicKeyPath)
if (-not (Test-Path -LiteralPath $resolvedKeyPath -PathType Leaf)) {
  throw "SSH public key file was not found: $resolvedKeyPath"
}

$publicKey = (Get-Content -LiteralPath $resolvedKeyPath -Raw).Trim()

$deploymentParameters = @(
  "location=$Location"
  "adminPublicKey=$publicKey"
)

if ($EndpointVmSize) {
  $deploymentParameters += "endpointVmSize=$EndpointVmSize"
}

if ($RouterVmSize) {
  $deploymentParameters += "routerVmSize=$RouterVmSize"
}

az group create `
  --name $ResourceGroupName `
  --location $Location `
  --output none

if ($LASTEXITCODE -ne 0) {
  throw "Resource group creation failed with exit code $LASTEXITCODE."
}

az deployment group create `
  --resource-group $ResourceGroupName `
  --name 'sabansal-routing' `
  --template-file "$PSScriptRoot\main.bicep" `
  --parameters "$PSScriptRoot\main.bicepparam" `
  --parameters $deploymentParameters `
  --output none

if ($LASTEXITCODE -ne 0) {
  throw "Azure deployment failed with exit code $LASTEXITCODE."
}

if ($RunConnectivityTest) {
  Write-Host ''
  Write-Host 'Deployment complete. Running the connectivity test...'
  Write-Host ''

  & "$PSScriptRoot\test-connectivity.ps1" `
    -ResourceGroupName $ResourceGroupName `
    -DeploymentName 'sabansal-routing' `
    -ParallelConnections $ParallelConnections `
    -DurationSeconds $DurationSeconds
}
