[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $ResourceGroupName,

  [Parameter(Mandatory)]
  [string] $Location,

  [switch] $SkipVirtualNetworks,

  [switch] $SkipGatewaysAndCircuit,

  [switch] $DeployTestVms,

  [switch] $VmsOnly,

  [string] $SshPublicKeyPath = '~\.ssh\id_ed25519.pub'
)

$ErrorActionPreference = 'Stop'

$resolvedKeyPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SshPublicKeyPath)
$deployVirtualNetworks = -not ($SkipVirtualNetworks.IsPresent -or $VmsOnly.IsPresent)
$deployGatewaysAndCircuit = -not ($SkipGatewaysAndCircuit.IsPresent -or $VmsOnly.IsPresent)
$deployTestVms = $DeployTestVms.IsPresent -or $VmsOnly.IsPresent

$deploymentParameters = @(
  "deployVirtualNetworks=$($deployVirtualNetworks.ToString().ToLowerInvariant())"
  "deployGatewaysAndCircuit=$($deployGatewaysAndCircuit.ToString().ToLowerInvariant())"
  "deployTestVms=$($deployTestVms.ToString().ToLowerInvariant())"
)

if ($deployTestVms) {
  if (-not (Test-Path -LiteralPath $resolvedKeyPath -PathType Leaf)) {
    throw "SSH public key file was not found: $resolvedKeyPath"
  }

  $publicKey = (Get-Content -LiteralPath $resolvedKeyPath -Raw).Trim()
  $deploymentParameters += "testVmAdminPublicKey=$publicKey"
}

$deploymentParameters += "location=$Location"
az group create `
  --name $ResourceGroupName `
  --location $Location `
  --output none

az deployment group create `
  --resource-group $ResourceGroupName `
  --template-file "$PSScriptRoot\main.bicep" `
  --parameters "$PSScriptRoot\main.bicepparam" `
  --parameters $deploymentParameters

if ($LASTEXITCODE -ne 0) {
  throw "Azure deployment failed with exit code $LASTEXITCODE."
}
