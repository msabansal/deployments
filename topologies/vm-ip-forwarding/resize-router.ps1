<#
.SYNOPSIS
  Changes the SKU of the router VM in a deployed topology.

.DESCRIPTION
  Resizing across hardware generations - for example from the Haswell/Broadwell hosts that run
  the Dv2 family to the Ice Lake hosts that run Dv5 - cannot be done in place, because the
  target size is not offered by the cluster the VM currently sits on. The VM is therefore
  deallocated, resized, and started again. Azure picks a new host on the way back up.

  Everything the topology depends on survives the cycle: the NIC keeps the static address the
  route tables point at, and the guest forwarding configuration is persisted on the OS disk
  (sysctl.d and firewalld on Linux, the registry and netsh on Windows), so it is re-applied
  automatically at boot.

  The script is a no-op when the VM already runs the requested size.

.EXAMPLE
  .\resize-router.ps1 -ResourceGroupName sabansal-rg-fwd -VmSize Standard_D2s_v5
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $ResourceGroupName,

  [Parameter(Mandatory)]
  [string] $VmSize,

  # Resolved from the deployment outputs when it is not supplied.
  [string] $VmName,

  [string] $DeploymentName = 'vm-ip-forwarding',

  [ValidateRange(1, 120)]
  [int] $TimeoutMinutes = 20
)

$ErrorActionPreference = 'Stop'

if (-not $VmName) {
  $VmName = az deployment group show `
    --resource-group $ResourceGroupName `
    --name $DeploymentName `
    --query properties.outputs.routerVmName.value `
    -o tsv

  if ($LASTEXITCODE -ne 0 -or -not $VmName) {
    throw "Could not read the router VM name from deployment '$DeploymentName' in '$ResourceGroupName'."
  }

  $VmName = $VmName.Trim()
}

$currentSize = az vm show --resource-group $ResourceGroupName --name $VmName `
  --query hardwareProfile.vmSize -o tsv

if ($LASTEXITCODE -ne 0 -or -not $currentSize) {
  throw "Could not read the current size of '$VmName' in '$ResourceGroupName'."
}

$currentSize = $currentSize.Trim()

if ($currentSize -eq $VmSize) {
  Write-Host "Router VM '$VmName' already runs $VmSize, nothing to do." -ForegroundColor Yellow
  return
}

# Families differ in which disk controllers they can boot from: the v6 sizes are NVMe only, while
# Dv2 and Dv5 are SCSI only. Moving between them without also switching the controller fails with
# "cannot boot with DiskControllerType", so work out what the target size actually accepts.
$location = az vm show --resource-group $ResourceGroupName --name $VmName --query location -o tsv
if ($LASTEXITCODE -ne 0 -or -not $location) {
  throw "Could not read the location of '$VmName' in '$ResourceGroupName'."
}
$location = $location.Trim()

$skuCacheKey = "$location/$VmSize"
if (-not $global:RouterSkuControllerCache) {
  $global:RouterSkuControllerCache = @{}
}

# Listing SKUs downloads the whole catalogue for the region and takes a minute or more, so hold on
# to the answer: the redeploy loop resizes to the same size on every iteration.
if ($global:RouterSkuControllerCache.ContainsKey($skuCacheKey)) {
  $supportedControllers = $global:RouterSkuControllerCache[$skuCacheKey]
}
else {
  $skuJson = az vm list-skus --location $location --resource-type virtualMachines --size $VmSize -o json 2>$null
  $targetSku = $null
  if ($LASTEXITCODE -eq 0 -and $skuJson) {
    $targetSku = $skuJson | ConvertFrom-Json | Where-Object { $_.name -eq $VmSize }
  }

  if (-not $targetSku) {
    throw "Size '$VmSize' is not available in '$location'."
  }

  # The capability is absent on families that only ever supported SCSI, which is the same as
  # advertising SCSI on its own.
  $controllerCapability = ($targetSku.capabilities | Where-Object { $_.name -eq 'DiskControllerTypes' }).value
  $supportedControllers = if ($controllerCapability) { $controllerCapability -split '\s*,\s*' } else { @('SCSI') }
  $global:RouterSkuControllerCache[$skuCacheKey] = $supportedControllers
}

$currentController = az vm show --resource-group $ResourceGroupName --name $VmName `
  --query storageProfile.diskControllerType -o tsv 2>$null
$currentController = if ($LASTEXITCODE -eq 0 -and $currentController) { $currentController.Trim() } else { 'SCSI' }

# Keep the current controller when the target can boot from it, so a resize within a family stays
# a plain resize. Otherwise prefer NVMe, which is the only option the newer families offer.
$targetController = if ($supportedControllers -contains $currentController) { $currentController }
elseif ($supportedControllers -contains 'NVMe') { 'NVMe' }
else { $supportedControllers[0] }

$controllerChanges = $targetController -ne $currentController

if ($controllerChanges) {
  Write-Host "  $VmSize cannot boot from $currentController, so the disk controller moves to $targetController." -ForegroundColor Yellow

  # The guest needs drivers for the new controller or it will boot to a stop. Every image this
  # topology uses advertises both, but a check here turns an unbootable VM into a clear error.
  $imageJson = az vm show --resource-group $ResourceGroupName --name $VmName --query storageProfile.imageReference -o json 2>$null
  if ($LASTEXITCODE -eq 0 -and $imageJson) {
    $image = $imageJson | ConvertFrom-Json

    if ($image.publisher -and $image.offer -and $image.sku) {
      $urn = '{0}:{1}:{2}:{3}' -f $image.publisher, $image.offer, $image.sku, $(if ($image.exactVersion) { $image.exactVersion } else { 'latest' })
      $imageDetailJson = az vm image show --location $location --urn $urn -o json 2>$null

      if ($LASTEXITCODE -eq 0 -and $imageDetailJson) {
        $imageControllers = (($imageDetailJson | ConvertFrom-Json).features | Where-Object { $_.name -eq 'DiskControllerTypes' }).value

        if ($imageControllers -and ($imageControllers -split '\s*,\s*') -notcontains $targetController) {
          throw "The image behind '$VmName' supports $imageControllers, so it cannot boot '$VmSize', which needs $targetController."
        }
      }
    }
  }
}

Write-Host "Resizing router VM '$VmName' from $currentSize to $VmSize..." -ForegroundColor Yellow

# Deallocating first is what makes a cross-generation resize possible: a running VM can only be
# moved to a size its current cluster offers.
az vm deallocate --resource-group $ResourceGroupName --name $VmName --only-show-errors | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "Deallocating '$VmName' failed with exit code $LASTEXITCODE."
}

if ($controllerChanges) {
  # Both have to move in one request. The controller cannot be changed on its own while the VM
  # still holds a size that does not support it, and the size cannot be changed on its own while
  # the disk is still attached to a controller the new size cannot boot from.
  az vm update `
    --resource-group $ResourceGroupName `
    --name $VmName `
    --set "hardwareProfile.vmSize=$VmSize" "storageProfile.diskControllerType=$targetController" `
    --only-show-errors | Out-Null
}
else {
  az vm resize --resource-group $ResourceGroupName --name $VmName --size $VmSize --only-show-errors | Out-Null
}

if ($LASTEXITCODE -ne 0) {
  # Leaving the VM deallocated would look like a router failure rather than a resize failure,
  # so bring it back at its original size before reporting the problem.
  Write-Warning "Resize to $VmSize failed. Starting '$VmName' again at $currentSize."
  az vm start --resource-group $ResourceGroupName --name $VmName --only-show-errors | Out-Null
  throw "Resizing '$VmName' to $VmSize failed with exit code $LASTEXITCODE."
}

az vm start --resource-group $ResourceGroupName --name $VmName --only-show-errors | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "Starting '$VmName' after the resize failed with exit code $LASTEXITCODE."
}

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)

while ((Get-Date) -lt $deadline) {
  $stateJson = az vm get-instance-view `
    --resource-group $ResourceGroupName `
    --name $VmName `
    --query "{power: instanceView.statuses[?starts_with(code, 'PowerState')].code | [0], agent: instanceView.vmAgent.statuses[?code == 'ProvisioningState/succeeded'] | length(@)}" `
    -o json 2>$null

  if ($LASTEXITCODE -eq 0 -and $stateJson) {
    $state = $stateJson | ConvertFrom-Json
    if ($state.power -eq 'PowerState/running' -and $state.agent -gt 0) {
      # The agent reports ready slightly before run-command reliably works.
      Start-Sleep -Seconds 20

      $newSize = (az vm show --resource-group $ResourceGroupName --name $VmName --query hardwareProfile.vmSize -o tsv).Trim()
      if ($newSize -ne $VmSize) {
        throw "'$VmName' reports size $newSize after the resize, expected $VmSize."
      }

      Write-Host "  router VM '$VmName' is running $VmSize." -ForegroundColor Green
      return
    }
  }

  Start-Sleep -Seconds 15
}

throw "The router VM '$VmName' did not become ready within $TimeoutMinutes minutes after resizing to $VmSize."
