[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidateNotNullOrEmpty()]
  [string] $ResourceGroupName,

  [Parameter(Mandatory)]
  [ValidateNotNullOrEmpty()]
  [string] $Location,

  [ValidateNotNullOrEmpty()]
  [ValidateLength(1, 59)]
  [ValidatePattern('\A(?i:[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?)\z')]
  [string] $VmName = 'azurelinux-vm',

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

if ($PSBoundParameters.ContainsKey('VmSize')) {
  $skuJson = az vm list-skus `
    --location $Location `
    --resource-type virtualMachines `
    --size $VmSize `
    --all `
    --output json

  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($skuJson)) {
    throw "Could not query capabilities for VM size '$VmSize' in '$Location'."
  }

  $sku = @($skuJson | ConvertFrom-Json) |
    Where-Object { $_.name -eq $VmSize } |
    Select-Object -First 1

  if (-not $sku) {
    throw "VM size '$VmSize' is not available in '$Location'."
  }

  $diskControllerCapability = $sku.capabilities |
    Where-Object { $_.name -eq 'DiskControllerTypes' } |
    Select-Object -First 1

  if (-not $diskControllerCapability) {
    throw "VM size '$VmSize' does not report its supported disk controller types."
  }

  $supportedDiskControllerTypes = @(
    $diskControllerCapability.value -split ',' |
      ForEach-Object { $_.Trim() } |
      Where-Object { $_ }
  )

  if ($PSBoundParameters.ContainsKey('DiskControllerType')) {
    if ($DiskControllerType -notin $supportedDiskControllerTypes) {
      throw "VM size '$VmSize' does not support disk controller '$DiskControllerType'. Supported types: $($supportedDiskControllerTypes -join ', ')."
    }
  }
  elseif ($supportedDiskControllerTypes.Count -eq 1) {
    $DiskControllerType = $supportedDiskControllerTypes[0]
    Write-Host "Using disk controller '$DiskControllerType' required by VM size '$VmSize'."
  }
}

$deploymentParameters = @(
  "location=$Location"
  "adminPublicKey=$publicKey"
  "vmName=$VmName"
)

if ($PSBoundParameters.ContainsKey('VmSize')) {
  $deploymentParameters += "vmSize=$VmSize"
}

if ($PSBoundParameters.ContainsKey('OsDiskStorageAccountType')) {
  $deploymentParameters += "osDiskStorageAccountType=$OsDiskStorageAccountType"
}

if ($DiskControllerType) {
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
  --name $VmName `
  --template-file "$PSScriptRoot\main.bicep" `
  --parameters "$PSScriptRoot\main.bicepparam" `
  --parameters $deploymentParameters `
  --query properties.outputs `
  --output json

if ($LASTEXITCODE -ne 0) {
  throw "Azure deployment failed with exit code $LASTEXITCODE."
}
