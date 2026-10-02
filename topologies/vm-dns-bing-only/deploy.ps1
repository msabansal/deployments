[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidateNotNullOrEmpty()]
  [string] $ResourceGroupName,

  [Parameter(Mandatory)]
  [ValidateNotNullOrEmpty()]
  [string] $Location,

  [ValidateLength(1, 50)]
  [ValidatePattern('\A(?i:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)\z')]
  [string] $VmName = 'vm-dns-bing-only',

  [string] $SshPublicKeyPath = '~\.ssh\id_ed25519.pub',

  [ValidateNotNullOrEmpty()]
  [string] $VmSize
)

$ErrorActionPreference = 'Stop'

$resolvedKeyPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SshPublicKeyPath)
if (-not (Test-Path -LiteralPath $resolvedKeyPath -PathType Leaf)) {
  throw "SSH public key file was not found: $resolvedKeyPath"
}

$publicKey = (Get-Content -LiteralPath $resolvedKeyPath -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($publicKey)) {
  throw "SSH public key file is empty: $resolvedKeyPath"
}

$deploymentParameters = @(
  "location=$Location"
  "adminPublicKey=$publicKey"
  "vmName=$VmName"
)
if ($PSBoundParameters.ContainsKey('VmSize')) {
  $deploymentParameters += "vmSize=$VmSize"
}

az group create --name $ResourceGroupName --location $Location --output none
if ($LASTEXITCODE -ne 0) {
  throw "Resource group creation failed with exit code $LASTEXITCODE."
}

az deployment group create `
  --resource-group $ResourceGroupName `
  --name $VmName `
  --template-file "$PSScriptRoot\main.bicep" `
  --parameters "$PSScriptRoot\main.bicepparam" `
  --parameters $deploymentParameters `
  --query properties.outputs `
  --output json
if ($LASTEXITCODE -ne 0) {
  throw "Azure deployment failed with exit code $LASTEXITCODE."
}
