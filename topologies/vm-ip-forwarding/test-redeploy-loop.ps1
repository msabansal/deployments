<#
.SYNOPSIS
  Runs one instance of the forwarding topology end to end: optionally deploys it, resizes the
  router, then loops running the throughput test and changing the router VM between iterations.

.DESCRIPTION
  This script owns everything that happens to a single resource group. It can deploy the
  topology, resize the router VM to a different SKU before anything is measured, and then loop:
  run test-connectivity.ps1, compare the result against a baseline, and change the router VM
  before going round again.

  The baseline is either supplied with -BaselineGbps or taken from the first iteration. While
  the throughput stays at or above -ThresholdPercent of the baseline the loop keeps going. It
  stops on the first iteration that falls below the threshold, which is the result worth
  capturing: it identifies a host or a placement that cannot sustain the expected forwarding
  rate. The path check inside test-connectivity.ps1 also gates every iteration, so a run that
  silently stopped traversing the router is reported as a failure rather than as throughput.

  Between iterations the router is changed in one of two ways, selected with -RouterChange:

    Redeploy  az vm redeploy, which moves the existing VM to a different host and keeps its
              disk. This is the cheaper of the two and tests placement.
    Recreate  the VM and its OS disk are deleted and the deployment is re-run, which builds a
              new VM from the image and re-applies the guest configuration. The NIC is left in
              place, so the router keeps the static address the route tables point at. When
              -InitialRouterVmSize and -ResizedRouterVmSize are both given the rebuilt VM goes
              through the same create-then-resize cycle as the initial deployment.

  test-fleet.ps1 runs this script against many resource groups in parallel.

.EXAMPLE
  .\test-redeploy-loop.ps1 -ResourceGroupName sabansal-rg-fwd

.EXAMPLE
  .\test-redeploy-loop.ps1 -ResourceGroupName sabansal-rg-fwd -BaselineGbps 7.43 -MaxIterations 20

.EXAMPLE
  .\test-redeploy-loop.ps1 -ResourceGroupName sabansal-fwd-01 -Location westus2 -Deploy `
    -RouterChange Recreate -IterationsBeforeChange 3 `
    -InitialRouterVmSize Standard_DS2_v2 -ResizedRouterVmSize Standard_D2s_v5
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $ResourceGroupName,

  [string] $DeploymentName = 'vm-ip-forwarding',

  # Deploy the topology before testing. Required when the resource group does not exist yet.
  [switch] $Deploy,

  # Only used when -Deploy is set.
  [string] $Location,

  [ValidateSet('AzureLinux', 'WindowsServer2022')]
  [string] $RouterOs = 'AzureLinux',

  [string] $SshPublicKeyPath = '~\.ssh\id_ed25519.pub',

  [securestring] $RouterAdminPassword,

  # Throughput in Gbits/sec that later iterations are measured against. When left at 0 the
  # first iteration establishes the baseline.
  [ValidateRange(0, 1000)]
  [double] $BaselineGbps = 0,

  [ValidateRange(1, 100)]
  [int] $ThresholdPercent = 80,

  # 0 means keep going until an iteration fails.
  [ValidateRange(0, 10000)]
  [int] $MaxIterations = 0,

  [ValidateRange(1, 128)]
  [int] $ParallelConnections = 8,

  [ValidateRange(5, 3600)]
  [int] $DurationSeconds = 60,

  [int] $Port = 5201,

  [switch] $Reverse,

  # What happens to the router VM between iterations.
  [ValidateSet('Redeploy', 'Recreate', 'None')]
  [string] $RouterChange = 'Redeploy',

  # Successful iterations between router changes.
  [ValidateRange(1, 1000)]
  [int] $IterationsBeforeChange = 1,

  # The SKU router VMs are created on, both by -Deploy and by a Recreate.
  [string] $InitialRouterVmSize,

  # When set, the router is resized to this SKU as soon as it is created, before anything is
  # measured against it.
  [string] $ResizedRouterVmSize,

  # Minutes to wait for the router VM to come back after a redeploy or a resize.
  [ValidateRange(1, 120)]
  [int] $RouterTimeoutMinutes = 20,

  # Written as CSV when set, so a long run can be inspected afterwards.
  [string] $ResultCsvPath,

  # Prefixed to every console line. test-fleet.ps1 sets this so the output of instances running
  # in parallel can be told apart.
  [string] $LogPrefix,

  # Optional shared dictionary used to stop early. When its 'abort' key becomes true the loop
  # stops at the next iteration boundary. test-fleet.ps1 passes one in so the first instance to
  # fail stops the rest of the fleet.
  [System.Collections.Concurrent.ConcurrentDictionary[string, object]] $AbortSignal,

  # Return the result object instead of exiting, so a caller can inspect the outcome.
  [switch] $PassThru
)

$ErrorActionPreference = 'Stop'

$testScript = Join-Path $PSScriptRoot 'test-connectivity.ps1'
$deployScript = Join-Path $PSScriptRoot 'deploy.ps1'
$resizeScript = Join-Path $PSScriptRoot 'resize-router.ps1'

foreach ($required in $testScript, $deployScript, $resizeScript) {
  if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
    throw "Could not find $(Split-Path -Leaf $required) next to this script."
  }
}

if ($Deploy -and -not $Location) {
  throw 'A location is required when -Deploy is set.'
}

if ($ResizedRouterVmSize -and $ResizedRouterVmSize -eq $InitialRouterVmSize) {
  throw 'InitialRouterVmSize and ResizedRouterVmSize are the same, so there is nothing to resize.'
}

if ($RouterOs -eq 'WindowsServer2022' -and $Deploy -and -not $RouterAdminPassword) {
  $RouterAdminPassword = Read-Host -AsSecureString -Prompt 'Administrator password for the Windows router VM'
}

function Write-Line {
  param([string] $Message, [string] $Colour = 'Gray')

  $text = if ($LogPrefix) { "[$LogPrefix] $Message" } else { $Message }
  Write-Host $text -ForegroundColor $Colour
}

function Test-ShouldStop {
  if (-not $AbortSignal) { return $false }
  return [bool]$AbortSignal['abort']
}

function Get-RouterVmName {
  $name = az deployment group show `
    --resource-group $ResourceGroupName `
    --name $DeploymentName `
    --query properties.outputs.routerVmName.value `
    -o tsv

  if ($LASTEXITCODE -ne 0 -or -not $name) {
    throw "Could not read the router VM name from deployment '$DeploymentName' in '$ResourceGroupName'."
  }

  return $name.Trim()
}

function Wait-VmReady {
  param(
    [Parameter(Mandatory)] [string] $VmName,
    [Parameter(Mandatory)] [int] $TimeoutMinutes
  )

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
        return
      }
    }

    Start-Sleep -Seconds 15
  }

  throw "The router VM '$VmName' did not become ready within $TimeoutMinutes minutes."
}

# Deleting a resource group is asynchronous, so a previous run that tore this group down can
# still be deleting it. Creating a group that is mid-deletion appears to succeed and then every
# operation inside it fails with OperationNotAllowed.
function Wait-ForPendingDelete {
  $deadline = (Get-Date).AddMinutes(30)
  $announced = $false

  while ((Get-Date) -lt $deadline) {
    $provisioningState = az group show --name $ResourceGroupName --query properties.provisioningState -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $provisioningState -or $provisioningState.Trim() -ne 'Deleting') {
      return
    }

    if (-not $announced) {
      Write-Line 'waiting for a previous run to finish deleting this resource group' 'Yellow'
      $announced = $true
    }

    Start-Sleep -Seconds 15
  }

  throw "Resource group '$ResourceGroupName' was still being deleted after 30 minutes."
}

function Invoke-Deployment {
  $deployArgs = @{
    ResourceGroupName   = $ResourceGroupName
    Location            = $Location
    RouterOs            = $RouterOs
    SshPublicKeyPath    = $SshPublicKeyPath
    RouterAdminPassword = $RouterAdminPassword
  }

  # Routers are always created on the initial size, so a Recreate repeats the same
  # create-then-resize cycle the initial deployment went through.
  if ($InitialRouterVmSize) { $deployArgs.RouterVmSize = $InitialRouterVmSize }

  & $deployScript @deployArgs
}

# Resizing to the size the VM already runs is a no-op inside resize-router.ps1, so this is safe
# to call after every router change.
function Invoke-RouterResize {
  param([Parameter(Mandatory)] [string] $VmName)

  if (-not $ResizedRouterVmSize) { return }

  Write-Line "resizing the router to $ResizedRouterVmSize..." 'Yellow'
  $started = Get-Date

  & $resizeScript `
    -ResourceGroupName $ResourceGroupName `
    -DeploymentName $DeploymentName `
    -VmName $VmName `
    -VmSize $ResizedRouterVmSize `
    -TimeoutMinutes $RouterTimeoutMinutes

  Write-Line ("resized in {0:N0} seconds" -f ((Get-Date) - $started).TotalSeconds) 'Green'
}

function Invoke-RouterRedeploy {
  param([Parameter(Mandatory)] [string] $VmName)

  Write-Line "redeploying the router VM '$VmName' onto a different host..." 'Yellow'
  $started = Get-Date

  az vm redeploy --resource-group $ResourceGroupName --name $VmName --only-show-errors | Out-Null

  if ($LASTEXITCODE -ne 0) {
    throw "Redeploy of '$VmName' failed with exit code $LASTEXITCODE."
  }

  Wait-VmReady -VmName $VmName -TimeoutMinutes $RouterTimeoutMinutes
  Write-Line ("router VM is running again after {0:N0} seconds" -f ((Get-Date) - $started).TotalSeconds) 'Green'
}

# Deleting the VM leaves the NIC in place, which matters: the router keeps the static address
# the route tables point at. The OS disk is not deleted with the VM, so it is removed explicitly
# to avoid leaking a disk on every rebuild.
function Invoke-RouterRecreate {
  param([Parameter(Mandatory)] [string] $VmName)

  Write-Line "rebuilding the router VM '$VmName'..." 'Yellow'
  $started = Get-Date

  $osDiskId = az vm show --resource-group $ResourceGroupName --name $VmName `
    --query storageProfile.osDisk.managedDisk.id -o tsv
  if ($LASTEXITCODE -ne 0) {
    throw "Could not read the OS disk of '$VmName' in '$ResourceGroupName'."
  }

  az vm delete --resource-group $ResourceGroupName --name $VmName --yes --only-show-errors | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Deleting '$VmName' failed with exit code $LASTEXITCODE."
  }

  if ($osDiskId) {
    az disk delete --ids $osDiskId.Trim() --yes --only-show-errors | Out-Null
  }

  Invoke-Deployment

  Write-Line ("router VM rebuilt in {0:N0} seconds" -f ((Get-Date) - $started).TotalSeconds) 'Green'
}

$threshold = $ThresholdPercent / 100.0
$results = New-Object System.Collections.Generic.List[object]
$iteration = 0
$successStreak = 0
$failureReason = $null
$routerVmName = $null
$routerVmSize = $(if ($InitialRouterVmSize) { $InitialRouterVmSize } else { 'template default' })
$routerChanges = 0

$summary = [pscustomobject]@{
  ResourceGroupName = $ResourceGroupName
  RouterVmSize      = $routerVmSize
  BaselineGbps      = $null
  LastGbps          = $null
  Iterations        = 0
  RouterChanges     = 0
  Status            = 'pending'
  Detail            = ''
  Succeeded         = $false
}

try {
  if ($Deploy) {
    if (Test-ShouldStop) {
      $summary.Status = 'skipped'
      $summary.Detail = 'another instance failed before this one deployed'
      Write-Line 'skipping, another instance failed' 'Yellow'
      if ($PassThru) { return $summary }
      return
    }

    Wait-ForPendingDelete

    Write-Line 'deploying...' 'Cyan'
    $started = Get-Date

    Invoke-Deployment

    Write-Line ("deployed in {0:N0} seconds" -f ((Get-Date) - $started).TotalSeconds) 'Green'
  }

  $routerVmName = Get-RouterVmName

  Invoke-RouterResize -VmName $routerVmName
  if ($ResizedRouterVmSize) {
    $routerVmSize = $ResizedRouterVmSize
    $summary.RouterVmSize = $routerVmSize
  }

  Write-Line ''
  Write-Line '########## continuous forwarding throughput test ##########' 'Cyan'
  Write-Line "  resource group : $ResourceGroupName"
  Write-Line "  router VM      : $routerVmName ($routerVmSize)"
  Write-Line "  acceptance     : at least $ThresholdPercent% of the baseline"
  Write-Line ("  router change  : {0}" -f $(if ($RouterChange -eq 'None') { 'none' } else { "$RouterChange every $IterationsBeforeChange successful iterations" }))
  if ($BaselineGbps -gt 0) {
    Write-Line ("  baseline       : {0:N2} Gbits/sec (supplied)" -f $BaselineGbps)
  }
  else {
    Write-Line '  baseline       : measured by the first iteration'
  }
  Write-Line ("  iterations     : {0}" -f $(if ($MaxIterations -gt 0) { $MaxIterations } else { 'until a failure' }))
  Write-Line '##########################################################' 'Cyan'

  while ($true) {
    if (Test-ShouldStop) {
      $summary.Status = 'stopped'
      $summary.Detail = 'another instance failed'
      Write-Line 'stopping, another instance failed' 'Yellow'
      break
    }

    $iteration++
    $summary.Iterations = $iteration

    Write-Line ''
    Write-Line "---------- iteration $iteration ----------" 'Cyan'

    $result = & $testScript `
      -ResourceGroupName $ResourceGroupName `
      -DeploymentName $DeploymentName `
      -ParallelConnections $ParallelConnections `
      -DurationSeconds $DurationSeconds `
      -Port $Port `
      -Reverse:$Reverse `
      -PassThru

    if (-not $result) {
      $failureReason = "Iteration ${iteration}: the throughput test returned no result."
      $summary.Status = 'no result'
      $summary.Detail = 'the connectivity test returned no measurement'
      break
    }

    if ($BaselineGbps -le 0) {
      $BaselineGbps = $result.GbpsSent
      Write-Line ("Baseline established at {0:N2} Gbits/sec. Later iterations must reach {1:N2} Gbits/sec." -f $BaselineGbps, ($BaselineGbps * $threshold)) 'Cyan'
    }

    $summary.BaselineGbps = [math]::Round($BaselineGbps, 3)
    $summary.LastGbps = [math]::Round($result.GbpsSent, 3)

    $percent = if ($BaselineGbps -gt 0) { $result.GbpsSent / $BaselineGbps * 100.0 } else { 0 }
    $acceptable = $result.GbpsSent -ge ($BaselineGbps * $threshold)

    $results.Add([pscustomobject]@{
        Iteration         = $iteration
        GbpsSent          = [math]::Round($result.GbpsSent, 3)
        PercentOfBaseline = [math]::Round($percent, 1)
        RouterVmSize      = $routerVmSize
        Status            = $(if ($acceptable) { 'acceptable' } else { 'below threshold' })
        Detail            = "first hop $($result.FirstHop), $($result.Retransmits) retransmits"
        TimestampUtc      = $result.TimestampUtc
      })

    if (-not $acceptable) {
      $failureReason = 'Iteration {0}: throughput was {1:N2} Gbits/sec, only {2:N1}% of the {3:N2} Gbits/sec baseline.' -f $iteration, $result.GbpsSent, $percent, $BaselineGbps
      $summary.Status = 'below threshold'
      $summary.Detail = '{0:N2} Gbits/sec is {1:N1}% of the {2:N2} Gbits/sec baseline' -f $result.GbpsSent, $percent, $BaselineGbps
      Write-Line $failureReason 'Red'
      break
    }

    $summary.Status = 'acceptable'
    $summary.Detail = "first hop $($result.FirstHop), $($result.Retransmits) retransmits"
    $summary.Succeeded = $true

    Write-Line ("iteration {0} is acceptable: {1:N2} Gbits/sec, {2:N1}% of the baseline." -f $iteration, $result.GbpsSent, $percent) 'Green'

    if ($MaxIterations -gt 0 -and $iteration -ge $MaxIterations) {
      Write-Line "Reached the requested iteration count of $MaxIterations." 'Cyan'
      break
    }

    if ($RouterChange -eq 'None') { continue }

    $successStreak++
    if ($successStreak -lt $IterationsBeforeChange) { continue }
    $successStreak = 0

    switch ($RouterChange) {
      'Redeploy' {
        Invoke-RouterRedeploy -VmName $routerVmName
      }
      'Recreate' {
        Invoke-RouterRecreate -VmName $routerVmName

        # The rebuild put the router back on the initial size, so it is resized again before the
        # next iteration measures anything.
        $routerVmSize = $(if ($InitialRouterVmSize) { $InitialRouterVmSize } else { 'template default' })
        Invoke-RouterResize -VmName $routerVmName
        if ($ResizedRouterVmSize) { $routerVmSize = $ResizedRouterVmSize }
        $summary.RouterVmSize = $routerVmSize
      }
    }

    $routerChanges++
    $summary.RouterChanges = $routerChanges
  }
}
catch {
  $failureReason = "Iteration ${iteration}: $($_.Exception.Message)"

  if ($summary.Status -in @('pending', 'acceptable')) {
    $summary.Status = $(if ($iteration -eq 0) { 'setup failed' } else { 'error' })
  }
  $summary.Detail = $_.Exception.Message

  $results.Add([pscustomobject]@{
      Iteration         = $iteration
      GbpsSent          = $null
      PercentOfBaseline = $null
      RouterVmSize      = $routerVmSize
      Status            = $summary.Status
      Detail            = $_.Exception.Message
      TimestampUtc      = (Get-Date).ToUniversalTime()
    })
}

if ($failureReason) { $summary.Succeeded = $false }

Write-Line ''
Write-Line '################## run summary ##################' 'Cyan'
Write-Line ("  resource group : {0}" -f $ResourceGroupName)
Write-Line ("  baseline       : {0:N2} Gbits/sec" -f $BaselineGbps)
Write-Line ("  threshold      : {0:N2} Gbits/sec ({1}%)" -f ($BaselineGbps * $threshold), $ThresholdPercent)
Write-Line ("  iterations     : {0}" -f $results.Count)
Write-Line ("  router changes : {0}" -f $routerChanges)
Write-Line ''

# Prefix every row individually. The fleet runs instances concurrently and their output
# interleaves, so an unprefixed block of table rows cannot be attributed to an instance.
($results | Format-Table -AutoSize | Out-String -Width 200).TrimEnd() -split "`r?`n" |
  ForEach-Object { Write-Line $_ }

if ($ResultCsvPath) {
  $results | Export-Csv -LiteralPath $ResultCsvPath -NoTypeInformation
  Write-Line "Results written to $ResultCsvPath"
}

Write-Line '#################################################' 'Cyan'

if ($failureReason) {
  Write-Line ''
  Write-Line "STOPPED: $failureReason" 'Red'
}
else {
  Write-Line ''
  Write-Line 'All iterations stayed within the acceptable throughput range.' 'Green'
}

if ($PassThru) {
  return $summary
}

if ($failureReason) { exit 1 }
