[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $ResourceGroupName,

  [Parameter(Mandatory)]
  [string] $Location
)

$ErrorActionPreference = 'Stop'

$deploymentParameters = @(
  "location=$Location"
)

az group create `
  --name $ResourceGroupName `
  --location $Location `
  --output none

if ($LASTEXITCODE -ne 0) {
  throw "Resource group creation failed with exit code $LASTEXITCODE."
}

az deployment group create `
  --resource-group $ResourceGroupName `
  --template-file "$PSScriptRoot\main.bicep" `
  --parameters "$PSScriptRoot\main.bicepparam" `
  --parameters $deploymentParameters

if ($LASTEXITCODE -ne 0) {
  throw "Azure deployment failed with exit code $LASTEXITCODE."
}
