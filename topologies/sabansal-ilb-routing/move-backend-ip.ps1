[CmdletBinding()]
param(
  [string] $ResourceGroupName = 'sabansal-ilb-routing-rg',

  [string] $DeploymentName = 'sabansal-ilb-routing',

  [Parameter(Mandatory)]
  [ValidateSet(1, 2)]
  [int] $DestinationRouter,

  [ValidateRange(10, 300)]
  [int] $TimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
$apiVersion = '2025-07-01'

$featureState = az feature show `
  --namespace Microsoft.Network `
  --name AllowMoveIpConfigurations `
  --query properties.state `
  --output tsv

if ($LASTEXITCODE -ne 0 -or $featureState -ne 'Registered') {
  throw @"
Atomic IP moves require the Microsoft.Network/AllowMoveIpConfigurations subscription feature.
Register it with:
  az feature register --namespace Microsoft.Network --name AllowMoveIpConfigurations
Then wait for the state to become Registered and run:
  az provider register --namespace Microsoft.Network
"@
}

$outputsJson = az deployment group show `
  --resource-group $ResourceGroupName `
  --name $DeploymentName `
  --query properties.outputs `
  --output json

if ($LASTEXITCODE -ne 0 -or -not $outputsJson) {
  throw "Could not read outputs from deployment '$DeploymentName'."
}

$outputs = $outputsJson | ConvertFrom-Json
$virtualNetworkName = $outputs.virtualNetworkName.value
$backendIp = $outputs.router1SecondaryIp.value
$router1NicName = $outputs.router1NicName.value
$router2NicName = $outputs.router2NicName.value
$destinationNicName = if ($DestinationRouter -eq 1) { $router1NicName } else { $router2NicName }

$nicJson = az network nic list `
  --resource-group $ResourceGroupName `
  --query "[?name=='$router1NicName' || name=='$router2NicName'].{id:id,name:name,ipConfigurations:ipConfigurations[].{id:id,name:name,privateIpAddress:privateIPAddress}}" `
  --output json

if ($LASTEXITCODE -ne 0 -or -not $nicJson) {
  throw 'Could not read router NIC IP configurations.'
}

$nics = @($nicJson | ConvertFrom-Json)
$sourceNic = $nics | Where-Object {
  @($_.ipConfigurations | Where-Object privateIpAddress -eq $backendIp).Count -eq 1
} | Select-Object -First 1

if (-not $sourceNic) {
  throw "No router NIC owns backend IP '$backendIp'."
}

if ($sourceNic.name -eq $destinationNicName) {
  Write-Host "Backend IP $backendIp is already assigned to $destinationNicName." -ForegroundColor Green
  return
}

$sourceIpConfiguration = $sourceNic.ipConfigurations |
  Where-Object privateIpAddress -eq $backendIp |
  Select-Object -First 1
$destinationNic = $nics | Where-Object name -eq $destinationNicName | Select-Object -First 1
if (-not $destinationNic) {
  throw "Destination NIC '$destinationNicName' was not found."
}

$targetIpConfigurationId = "$($destinationNic.id)/ipConfigurations/$($sourceIpConfiguration.name)"
$body = @{
  moveIpConfigurationItems = @(
    @{
      sourceIpConfiguration = @{ id = $sourceIpConfiguration.id }
      targetIpConfiguration = @{ id = $targetIpConfigurationId }
    }
  )
} | ConvertTo-Json -Depth 6 -Compress

$subscriptionId = az account show --query id --output tsv
if ($LASTEXITCODE -ne 0 -or -not $subscriptionId) {
  throw 'Could not determine the active Azure subscription.'
}

$moveUrl = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Network/virtualNetworks/$virtualNetworkName/moveIpConfigurations?api-version=$apiVersion"
$startedAt = Get-Date
$bodyFile = Join-Path ([System.IO.Path]::GetTempPath()) ("move-ip-configurations-{0}.json" -f [guid]::NewGuid())
$body | Set-Content -NoNewline -Encoding utf8 $bodyFile

Write-Host "Moving $backendIp from $($sourceNic.name) to $destinationNicName atomically..."
try {
  az rest `
    --method post `
    --url $moveUrl `
    --headers 'Content-Type=application/json' `
    --body "@$bodyFile" `
    --output none
  if ($LASTEXITCODE -ne 0) {
    throw "Atomic backend IP move failed with exit code $LASTEXITCODE."
  }
}
finally {
  Remove-Item -LiteralPath $bodyFile -ErrorAction SilentlyContinue
}

$deadline = $startedAt.AddSeconds($TimeoutSeconds)
do {
  Start-Sleep -Seconds 1
  $owner = az network nic list `
    --resource-group $ResourceGroupName `
    --query "[?ipConfigurations[?privateIPAddress=='$backendIp']].name | [0]" `
    --output tsv

  if ($LASTEXITCODE -ne 0) {
    throw 'Could not verify backend IP ownership after the move.'
  }
} while ($owner -ne $destinationNicName -and (Get-Date) -lt $deadline)

if ($owner -ne $destinationNicName) {
  throw "Backend IP ownership did not move to '$destinationNicName' within $TimeoutSeconds seconds."
}

$elapsed = (Get-Date) - $startedAt
Write-Host ("Backend IP {0} now belongs to {1}; control-plane move completed in {2:N1} seconds." -f `
    $backendIp, $destinationNicName, $elapsed.TotalSeconds) -ForegroundColor Green
