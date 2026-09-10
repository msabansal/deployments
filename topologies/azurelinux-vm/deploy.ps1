[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidateNotNullOrEmpty()]
  [string] $ResourceGroupName,

  [Parameter(Mandatory)]
  [ValidateNotNullOrEmpty()]
  [string] $Location,

  [string] $SshPublicKeyPath = '~\.ssh\id_ed25519.pub',

  [ValidateNotNullOrEmpty()]
  [ValidatePattern('\S')]
  [string] $VmSize,

  [ValidateSet('Standard_LRS', 'StandardSSD_LRS', 'Premium_LRS')]
  [string] $OsDiskStorageAccountType,

  [ValidateSet('SCSI', 'NVMe')]
  [string] $DiskControllerType,

  [ValidateNotNullOrEmpty()]
  [ValidateLength(3, 63)]
  [ValidatePattern('\A(?-i:[a-z][a-z0-9-]*[a-z0-9])\z')]
  [string] $PublicIpDnsLabel
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
)

if ($PSBoundParameters.ContainsKey('VmSize')) {
  $deploymentParameters += "vmSize=$VmSize"
}

if ($PSBoundParameters.ContainsKey('OsDiskStorageAccountType')) {
  $deploymentParameters += "osDiskStorageAccountType=$OsDiskStorageAccountType"
}

if ($PSBoundParameters.ContainsKey('DiskControllerType')) {
  $deploymentParameters += "diskControllerType=$DiskControllerType"
}

if ($PSBoundParameters.ContainsKey('PublicIpDnsLabel')) {
  $deploymentParameters += "publicIpDnsLabel=$PublicIpDnsLabel"
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
  --name 'azurelinux-vm' `
  --template-file "$PSScriptRoot\main.bicep" `
  --parameters "$PSScriptRoot\main.bicepparam" `
  --parameters $deploymentParameters `
  --query properties.outputs `
  --output json

if ($LASTEXITCODE -ne 0) {
  throw "Azure deployment failed with exit code $LASTEXITCODE."
}
