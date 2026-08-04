[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $ResourceGroupName,

  [Parameter(Mandatory)]
  [string] $Location,

  [ValidateSet('AzureLinux', 'WindowsServer2022')]
  [string] $RouterOs = 'AzureLinux',

  [string] $SshPublicKeyPath = '~\.ssh\id_ed25519.pub',

  # Overrides the router size baked into main.bicepparam. The endpoint VMs are unaffected.
  [string] $RouterVmSize,

  # When set, the router is resized to this SKU once the deployment finishes, before anything is
  # measured. Combined with -RouterVmSize this creates the router on one size and moves it to
  # another, which is the cycle the fleet and loop tests repeat on every rebuild.
  [string] $ResizedRouterVmSize,

  [securestring] $RouterAdminPassword,

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
  "routerOs=$RouterOs"
  "adminPublicKey=$publicKey"
)

if ($RouterVmSize) {
  $deploymentParameters += "routerVmSize=$RouterVmSize"
}

if ($RouterOs -eq 'WindowsServer2022') {
  if (-not $RouterAdminPassword) {
    $RouterAdminPassword = Read-Host -AsSecureString -Prompt 'Administrator password for the Windows router VM'
  }

  $plainPassword = [System.Net.NetworkCredential]::new('', $RouterAdminPassword).Password
  if ([string]::IsNullOrWhiteSpace($plainPassword)) {
    throw 'A router administrator password is required when RouterOs is WindowsServer2022.'
  }

  $deploymentParameters += "routerAdminPassword=$plainPassword"
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
  --name 'vm-ip-forwarding' `
  --template-file "$PSScriptRoot\main.bicep" `
  --parameters "$PSScriptRoot\main.bicepparam" `
  --parameters $deploymentParameters

if ($LASTEXITCODE -ne 0) {
  throw "Azure deployment failed with exit code $LASTEXITCODE."
}

if ($ResizedRouterVmSize) {
  Write-Host ''
  & "$PSScriptRoot\resize-router.ps1" `
    -ResourceGroupName $ResourceGroupName `
    -DeploymentName 'vm-ip-forwarding' `
    -VmSize $ResizedRouterVmSize
}

if ($RunConnectivityTest) {
  Write-Host ''
  Write-Host 'Deployment complete. Running the connectivity test...'
  Write-Host ''

  & "$PSScriptRoot\test-connectivity.ps1" `
    -ResourceGroupName $ResourceGroupName `
    -DeploymentName 'vm-ip-forwarding' `
    -ParallelConnections $ParallelConnections `
    -DurationSeconds $DurationSeconds
}
