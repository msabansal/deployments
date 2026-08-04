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

# The v6 sizes boot from NVMe only while Dv2 and Dv5 boot from SCSI only, so a resize between them
# has to move the disk controller as well. Asking az which controllers a size accepts means listing
# the whole SKU catalogue for the region, which takes a minute or more, so instead let the first
# resize attempt fail and read the answer out of the error. There are only two controllers, so the
# fix is always to flip to the other one.
$currentController = az vm show --resource-group $ResourceGroupName --name $VmName `
  --query storageProfile.diskControllerType -o tsv 2>$null
$currentController = if ($LASTEXITCODE -eq 0 -and $currentController) { $currentController.Trim() } else { 'SCSI' }

$vmId = az vm show --resource-group $ResourceGroupName --name $VmName --query id -o tsv
if ($LASTEXITCODE -ne 0 -or -not $vmId) {
  throw "Could not read the resource id of '$VmName' in '$ResourceGroupName'."
}
$vmId = $vmId.Trim()

$otherController = if ($currentController -eq 'NVMe') { 'SCSI' } else { 'NVMe' }

if (-not $global:RouterSizeControllerCache) {
  $global:RouterSizeControllerCache = @{}
}

# Once a size is known to need a controller the loop pays the failed attempt only that one time:
# every later iteration resizing to the same size goes straight to the combined update.
$knownController = $global:RouterSizeControllerCache[$VmSize]
$controllerChanges = $knownController -and $knownController -ne $currentController
$targetController = if ($controllerChanges) { $knownController } else { $currentController }

Write-Host "Resizing router VM '$VmName' from $currentSize to $VmSize..." -ForegroundColor Yellow

# Deallocating first is what makes a cross-generation resize possible: a running VM can only be
# moved to a size its current cluster offers.
az vm deallocate --resource-group $ResourceGroupName --name $VmName --only-show-errors | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "Deallocating '$VmName' failed with exit code $LASTEXITCODE."
}

# Size and controller have to move in one request. The controller cannot be changed on its own
# while the VM still holds a size that does not support it, and the size cannot be changed on its
# own while the disk is still attached to a controller the new size cannot boot from.
function Set-VmSizeAndController {
  param([string]$Controller)

  Write-Host "  $VmSize cannot boot from $currentController, so the disk controller moves to $Controller." -ForegroundColor Yellow

  # This is deliberately a PATCH rather than "az vm update", which reads the whole VM and writes it
  # back. The VM it reads does not carry the OS disk storage account type, so the write-back clears
  # it, and once that field is empty the platform refuses to let anything set it again through the
  # VM. A later redeploy sends the type the template asks for and fails with "Managed disk storage
  # account type change through Virtual Machine is not allowed", which leaves the topology stuck
  # until the VM is recreated. A PATCH only carries the two properties below, so nothing else moves.
  $body = @{
    properties = @{
      hardwareProfile = @{ vmSize = $VmSize }
      storageProfile  = @{ diskControllerType = $Controller }
    }
  } | ConvertTo-Json -Depth 5 -Compress

  $bodyFile = [System.IO.Path]::GetTempFileName()

  try {
    [System.IO.File]::WriteAllText($bodyFile, $body)
    $output = az rest --method patch `
      --url "https://management.azure.com$($vmId)?api-version=2024-07-01" `
      --body "@$bodyFile" `
      --only-show-errors 2>&1 | Out-String
  }
  finally {
    Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue
  }

  if ($LASTEXITCODE -ne 0) {
    return $output
  }

  # A PATCH returns as soon as the request is accepted, so wait for the VM to settle before the
  # caller tries to start it.
  $deadline = (Get-Date).AddMinutes(10)

  while ((Get-Date) -lt $deadline) {
    $state = az vm show --resource-group $ResourceGroupName --name $VmName --query provisioningState -o tsv 2>$null

    if ($LASTEXITCODE -eq 0 -and $state) {
      $state = $state.Trim()

      if ($state -eq 'Succeeded') {
        $global:LASTEXITCODE = 0
        return $output
      }

      if ($state -eq 'Failed') {
        $global:LASTEXITCODE = 1
        return "$output`nThe VM reached provisioning state 'Failed' after the size and controller change."
      }
    }

    Start-Sleep -Seconds 5
  }

  $global:LASTEXITCODE = 1
  return "$output`nThe VM did not finish updating within 10 minutes."
}

if ($controllerChanges) {
  $resizeOutput = Set-VmSizeAndController -Controller $targetController
}
else {
  $resizeOutput = az vm resize --resource-group $ResourceGroupName --name $VmName --size $VmSize --only-show-errors 2>&1 | Out-String

  if ($LASTEXITCODE -ne 0 -and $resizeOutput -match 'DiskControllerType') {
    $targetController = $otherController
    $controllerChanges = $true
    $global:RouterSizeControllerCache[$VmSize] = $targetController
    $resizeOutput = Set-VmSizeAndController -Controller $targetController
  }
}

if ($LASTEXITCODE -ne 0) {
  # Leaving the VM deallocated would look like a router failure rather than a resize failure,
  # so bring it back at its original size before reporting the problem.
  Write-Warning "Resize to $VmSize failed. Starting '$VmName' again at $currentSize."
  az vm start --resource-group $ResourceGroupName --name $VmName --only-show-errors | Out-Null
  throw "Resizing '$VmName' to $VmSize failed with exit code $LASTEXITCODE.`n$($resizeOutput.Trim())"
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
