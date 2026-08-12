<#
.SYNOPSIS
  Changes the SKU of the router VM in a deployed topology.

.DESCRIPTION
  Resizing across hardware generations - for example from the Haswell/Broadwell hosts that run
  the Dv2 family to the Ice Lake hosts that run Dv5 - cannot be done in place, because the
  target size is not offered by the cluster the VM currently sits on. The VM is therefore
  deallocated, resized, and started again. Azure picks a new host on the way back up.

  Everything the topology depends on survives the cycle on Linux: the NIC keeps the static address
  the route tables point at, and the guest forwarding configuration is persisted on the OS disk
  (sysctl.d and firewalld), so it is re-applied automatically at boot. The Windows router keeps its
  address and firewall rules, but forwarding itself is not persisted while the `IPEnableRouter`
  registry value is disabled, so it has to be re-applied by a redeploy after a resize.

  Moving between a SCSI-only size (Dv2, Dv4, Dv5) and an NVMe-only size (Dv6, Dv7) also changes the
  disk controller, which needs more than a resize. The guest is prepared first so it can see the new
  controller at boot, then the OS disk is told it may attach to either controller, and only then are
  the size and the controller changed together. Skipping the guest preparation is what makes a
  converted VM hang at boot. See
  https://learn.microsoft.com/azure/virtual-machines/enable-nvme-remote-faqs and
  https://learn.microsoft.com/azure/virtual-machines/nvme-linux.

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

# The v6 and v7 sizes boot from NVMe only while Dv2, Dv4 and Dv5 boot from SCSI only, so a resize
# between them has to move the disk controller as well. Asking az which controllers a size accepts
# means listing the whole SKU catalogue for the region, which takes a minute or more, so instead
# let the first resize attempt fail and read the answer out of the error. There are only two
# controllers, so the fix is always to flip to the other one.
$vmJson = az vm show --resource-group $ResourceGroupName --name $VmName -o json 2>$null
if ($LASTEXITCODE -ne 0 -or -not $vmJson) {
  throw "Could not read '$VmName' in '$ResourceGroupName'."
}

$vm = $vmJson | ConvertFrom-Json
$vmId = $vm.id
$osDiskId = $vm.storageProfile.osDisk.managedDisk.id
$osType = $vm.storageProfile.osDisk.osType
$currentController = if ($vm.storageProfile.diskControllerType) { $vm.storageProfile.diskControllerType } else { 'SCSI' }

# Trusted Launch permanently locks the controller type on the OS disk, so such a VM can never be
# converted. The topology does not enable it, but a VM created from an image that defaults to it
# would fail here with an opaque platform error, so say so plainly instead.
$isTrustedLaunch = $vm.securityProfile.securityType -eq 'TrustedLaunch'

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

# Making the guest NVMe-ready has to happen while the VM is still running, and the flip to NVMe is
# only discovered after a failed resize, by which point the VM is deallocated. So the preparation
# runs up front whenever the VM sits on SCSI. It is harmless on a VM that stays on SCSI: loading the
# NVMe drivers early and raising their I/O timeout changes nothing when no NVMe disk is attached.
# Skipping it is what makes a converted VM fail to boot - the guest comes up without a driver for
# the controller its OS disk now hangs off.
# https://learn.microsoft.com/azure/virtual-machines/nvme-linux
if ($currentController -eq 'SCSI' -and $knownController -ne 'SCSI') {
  if ($osType -eq 'Windows') {
    # Windows ships stornvme as a demand-start driver. Boot-start is what lets it attach the OS
    # disk during startup instead of bugchecking on an inaccessible boot device.
    $prepCommandId = 'RunPowerShellScript'
    $prepScript = @'
$ErrorActionPreference = 'Stop'
$state = (sc.exe qc stornvme) -join "`n"
if ($state -notmatch 'BOOT_START') {
  sc.exe config stornvme start=boot | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "sc.exe config stornvme failed with exit code $LASTEXITCODE." }
  Write-Output 'stornvme set to boot start.'
}
else {
  Write-Output 'stornvme already starts at boot.'
}
'@
  }
  else {
    # The kernel has to find the NVMe modules in the initrd, and the 30 second default I/O timeout
    # is too short for remote NVMe on Azure Boost hosts, which shows up as a panic during boot.
    $prepCommandId = 'RunShellScript'
    $prepScript = @'
set -u
changed=0

if [ -f /etc/default/grub ] && ! grep -q 'nvme_core.io_timeout' /etc/default/grub; then
  sed -i 's/^\(GRUB_CMDLINE_LINUX="[^"]*\)"/\1 nvme_core.io_timeout=240"/' /etc/default/grub
  changed=1
fi

if [ "$changed" = "1" ]; then
  for cfg in /boot/grub2/grub.cfg /boot/efi/EFI/*/grub.cfg /boot/grub/grub.cfg; do
    if [ -f "$cfg" ]; then
      grub2-mkconfig -o "$cfg" >/dev/null 2>&1 || grub-mkconfig -o "$cfg" >/dev/null 2>&1 || true
    fi
  done
  echo "added nvme_core.io_timeout=240 to the kernel command line"
fi

if command -v dracut >/dev/null 2>&1; then
  mkdir -p /etc/dracut.conf.d
  if [ ! -f /etc/dracut.conf.d/90-nvme.conf ]; then
    echo 'add_drivers+=" nvme nvme-core "' > /etc/dracut.conf.d/90-nvme.conf
    dracut --force --regenerate-all >/dev/null 2>&1 || dracut --force >/dev/null 2>&1
    echo "rebuilt the initrd with the nvme modules"
  fi
elif command -v update-initramfs >/dev/null 2>&1; then
  if ! grep -qx 'nvme' /etc/initramfs-tools/modules 2>/dev/null; then
    printf 'nvme\nnvme_core\n' >> /etc/initramfs-tools/modules
    update-initramfs -u -k all >/dev/null 2>&1
    echo "rebuilt the initramfs with the nvme modules"
  fi
fi

# NVMe namespaces are not numbered in a stable order, so an fstab that names /dev/sd* devices
# mounts the wrong volume - or nothing at all - once the controller changes.
if grep -Eq '^[[:space:]]*/dev/sd' /etc/fstab; then
  echo "WARNING: /etc/fstab refers to /dev/sd* devices, which do not survive the move to NVMe."
fi

echo "guest is ready for NVMe"
'@
  }

  Write-Host "  preparing the guest OS for NVMe..." -ForegroundColor DarkGray

  $prepFile = [System.IO.Path]::GetTempFileName()

  try {
    [System.IO.File]::WriteAllText($prepFile, $prepScript)
    $prepOutput = az vm run-command invoke `
      --resource-group $ResourceGroupName `
      --name $VmName `
      --command-id $prepCommandId `
      --scripts "@$prepFile" `
      --only-show-errors 2>&1 | Out-String
  }
  finally {
    Remove-Item $prepFile -Force -ErrorAction SilentlyContinue
  }

  # A guest that cannot be prepared will not boot from NVMe, so this is fatal rather than a warning.
  if ($LASTEXITCODE -ne 0) {
    throw "Preparing the guest of '$VmName' for NVMe failed with exit code $LASTEXITCODE.`n$($prepOutput.Trim())"
  }
}

# Deallocating first is what makes a cross-generation resize possible: a running VM can only be
# moved to a size its current cluster offers.
az vm deallocate --resource-group $ResourceGroupName --name $VmName --only-show-errors | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "Deallocating '$VmName' failed with exit code $LASTEXITCODE."
}

# Everything below patches ARM directly rather than going through "az vm update", which reads the
# whole VM and writes it back. The VM it reads does not carry the OS disk storage account type, so
# the write-back clears it, and once that field is empty the platform refuses to let anything set it
# again through the VM. A later redeploy sends the type the template asks for and fails with
# "Managed disk storage account type change through Virtual Machine is not allowed", which leaves
# the topology stuck until the VM is recreated. A PATCH only carries the properties in its body.
function Invoke-ArmPatch {
  param(
    [string] $ResourceId,
    [string] $ApiVersion,
    [hashtable] $Body
  )

  $json = $Body | ConvertTo-Json -Depth 6 -Compress
  $bodyFile = [System.IO.Path]::GetTempFileName()

  try {
    [System.IO.File]::WriteAllText($bodyFile, $json)
    return az rest --method patch `
      --url "https://management.azure.com$($ResourceId)?api-version=$ApiVersion" `
      --body "@$bodyFile" `
      --only-show-errors 2>&1 | Out-String
  }
  finally {
    Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue
  }
}

# Size and controller have to move in one request. The controller cannot be changed on its own
# while the VM still holds a size that does not support it, and the size cannot be changed on its
# own while the disk is still attached to a controller the new size cannot boot from.
function Set-VmSizeAndController {
  param([string]$Controller)

  Write-Host "  $VmSize cannot boot from $currentController, so the disk controller moves to $Controller." -ForegroundColor Yellow

  if ($isTrustedLaunch) {
    $global:LASTEXITCODE = 1
    return "'$VmName' uses Trusted Launch, and the disk controller type of a Trusted Launch VM cannot be changed. Recreate the topology on $VmSize instead of resizing into it."
  }

  # The disk carries its own list of controllers it may be attached to, and the VM update is
  # rejected when the disk does not advertise the target one. Widening it to both keeps the resize
  # working in either direction, so the loop can move back down to a SCSI size afterwards.
  if ($osDiskId) {
    $diskOutput = Invoke-ArmPatch -ResourceId $osDiskId -ApiVersion '2023-04-02' -Body @{
      properties = @{
        supportedCapabilities = @{ diskControllerTypes = 'SCSI, NVMe' }
      }
    }

    if ($LASTEXITCODE -ne 0) {
      return "Updating the supported disk controllers on the OS disk failed.`n$diskOutput"
    }
  }

  $output = Invoke-ArmPatch -ResourceId $vmId -ApiVersion '2024-07-01' -Body @{
    properties = @{
      hardwareProfile = @{ vmSize = $VmSize }
      storageProfile  = @{ diskControllerType = $Controller }
    }
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
