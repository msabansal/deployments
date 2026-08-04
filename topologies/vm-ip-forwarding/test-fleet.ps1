<#
.SYNOPSIS
  Deploys the forwarding topology into several resource groups, runs the connectivity test in
  all of them in parallel, and periodically deletes and recreates the router VM.

.DESCRIPTION
  Creates N resource groups named "<prefix>-01" .. "<prefix>-NN", deploys the topology into
  each of them, and then loops. Every iteration runs test-connectivity.ps1 against all the
  resource groups at the same time. Each instance measures its own baseline on its first
  successful iteration, because throughput depends on the hosts a given deployment landed on.

  After every M consecutive successful iterations the router VM is deleted outright, along with
  its OS disk, and recreated by re-running the deployment. The NIC survives, so the router keeps
  its static address and the route tables stay valid. This exercises a full rebuild rather than
  the host move that test-redeploy-loop.ps1 performs.

  The run stops as soon as any single instance fails: a failed path check, throughput below the
  threshold, a deployment error, or a router that does not come back. The per-instance result
  table is printed either way.

  Optionally the routers can be created on one SKU and moved to another one before any traffic
  is measured, with -InitialRouterVmSize and -ResizedRouterVmSize. Every time a router VM comes
  into existence - the initial deployment and every later rebuild - it is created on the initial
  size and immediately resized to the target size, before the next iteration runs. Every
  measurement therefore happens on the target size, and every rebuild exercises the create-then-
  resize cycle rather than only the first one.

.EXAMPLE
  .\test-fleet.ps1 -ResourceGroupPrefix sabansal-fwd -Location westus2 -InstanceCount 4

.EXAMPLE
  .\test-fleet.ps1 -ResourceGroupPrefix sabansal-fwd -Location westus2 -InstanceCount 4 `
    -IterationsBeforeRecreate 5 -MaxIterations 50 -SkipDeploy

.EXAMPLE
  .\test-fleet.ps1 -ResourceGroupPrefix sabansal-fwd -Location westus2 -InstanceCount 2 `
    -InitialRouterVmSize Standard_DS2_v2 -ResizedRouterVmSize Standard_D2s_v5
#>
[CmdletBinding()]
param(
  # Resource groups are named "<prefix>-01", "<prefix>-02", and so on.
  [Parameter(Mandatory)]
  [string] $ResourceGroupPrefix,

  [Parameter(Mandatory)]
  [string] $Location,

  # N: how many independent copies of the topology to run against.
  [ValidateRange(1, 50)]
  [int] $InstanceCount = 3,

  # M: successful iterations between router VM rebuilds.
  [ValidateRange(1, 1000)]
  [int] $IterationsBeforeRecreate = 3,

  # 0 means keep going until an instance fails.
  [ValidateRange(0, 10000)]
  [int] $MaxIterations = 0,

  [ValidateSet('AzureLinux', 'WindowsServer2022')]
  [string] $RouterOs = 'AzureLinux',

  [string] $SshPublicKeyPath = '~\.ssh\id_ed25519.pub',

  # Create the router VMs on this size instead of the one in main.bicepparam. Applies to the
  # initial deployment and to every later rebuild.
  [string] $InitialRouterVmSize,

  # When set, a router is resized to this SKU as soon as it is created, before any traffic is
  # measured against it. Combined with -InitialRouterVmSize this makes every router go through
  # a create-on-one-size then resize-to-another cycle, on the initial deploy and on every
  # rebuild.
  [string] $ResizedRouterVmSize,

  [ValidateRange(1, 120)]
  [int] $ResizeTimeoutMinutes = 20,

  [securestring] $RouterAdminPassword,

  [ValidateRange(1, 128)]
  [int] $ParallelConnections = 8,

  [ValidateRange(5, 3600)]
  [int] $DurationSeconds = 60,

  # Throughput floor for iterations after the first, as a percentage of the instance baseline.
  [ValidateRange(1, 100)]
  [int] $ThresholdPercent = 80,

  # Apply the same baseline to every instance instead of measuring one per instance.
  [ValidateRange(0, 1000)]
  [double] $BaselineGbps = 0,

  # Reuse resource groups that are already deployed.
  [switch] $SkipDeploy,

  [switch] $DeleteResourceGroupsOnExit,

  # How many instances to work on at once. Defaults to all of them.
  [ValidateRange(0, 50)]
  [int] $MaxParallel = 0,

  [string] $LogDirectory
)

$ErrorActionPreference = 'Stop'

$deployScript = Join-Path $PSScriptRoot 'deploy.ps1'
$testScript = Join-Path $PSScriptRoot 'test-connectivity.ps1'
$resizeScript = Join-Path $PSScriptRoot 'resize-router.ps1'

foreach ($required in $deployScript, $testScript, $resizeScript) {
  if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
    throw "Could not find $(Split-Path -Leaf $required) next to this script."
  }
}

if ($ResizedRouterVmSize -and $ResizedRouterVmSize -eq $InitialRouterVmSize) {
  throw 'InitialRouterVmSize and ResizedRouterVmSize are the same, so there is nothing to resize.'
}

# A wrong or unavailable SKU otherwise surfaces minutes later, after N deployments have already
# been started, so check both sizes against the target region up front.
$requestedSizes = @($InitialRouterVmSize, $ResizedRouterVmSize) | Where-Object { $_ }

if ($requestedSizes) {
  $availableSizes = az vm list-skus --location $Location --resource-type virtualMachines --query '[].name' -o tsv
  if ($LASTEXITCODE -ne 0 -or -not $availableSizes) {
    throw "Could not list the VM sizes available in '$Location'."
  }

  $availableSizes = @($availableSizes -split '\r?\n' | Where-Object { $_ })

  foreach ($size in $requestedSizes) {
    if ($availableSizes -notcontains $size) {
      $suggestions = $availableSizes | Where-Object { $_ -like "*$($size -replace '^Standard_', '')*" } | Select-Object -First 5
      $hint = if ($suggestions) { " Did you mean: $($suggestions -join ', ')?" } else { '' }
      throw "VM size '$size' is not available in '$Location'.$hint"
    }
  }
}

if ($RouterOs -eq 'WindowsServer2022' -and -not $RouterAdminPassword) {
  $RouterAdminPassword = Read-Host -AsSecureString -Prompt 'Administrator password for the Windows router VMs'
}

if (-not $LogDirectory) {
  $LogDirectory = Join-Path $PSScriptRoot ('fleet-logs-{0:yyyyMMdd-HHmmss}' -f (Get-Date))
}
New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null

if ($MaxParallel -le 0) { $MaxParallel = $InstanceCount }

$resourceGroups = 1..$InstanceCount | ForEach-Object { '{0}-{1:d2}' -f $ResourceGroupPrefix, $_ }

# Deleting a resource group is asynchronous, so a previous run that tore its groups down can
# still be deleting them. Creating a group that is mid-deletion appears to succeed and then
# every operation inside it fails with OperationNotAllowed, so wait for the deletes to finish.
function Wait-ForPendingDeletes {
  param([string[]] $Names)

  $deadline = (Get-Date).AddMinutes(30)
  $announced = $false

  foreach ($name in $Names) {
    while ((Get-Date) -lt $deadline) {
      $provisioningState = az group show --name $name --query properties.provisioningState -o tsv 2>$null
      if ($LASTEXITCODE -ne 0 -or -not $provisioningState -or $provisioningState.Trim() -ne 'Deleting') {
        break
      }

      if (-not $announced) {
        Write-Host ''
        Write-Host 'Waiting for resource groups left over from a previous run to finish deleting...' -ForegroundColor Yellow
        $announced = $true
      }

      Start-Sleep -Seconds 15
    }
  }
}

# Per-instance state, keyed by resource group name.
$state = [ordered]@{}
foreach ($rg in $resourceGroups) {
  $state[$rg] = [pscustomobject]@{
    ResourceGroupName    = $rg
    BaselineGbps         = $BaselineGbps
    LastGbps             = $null
    RouterVmSize         = $(if ($InitialRouterVmSize) { $InitialRouterVmSize } else { 'template default' })
    Iterations           = 0
    RouterRebuilds       = 0
    Status               = 'pending'
    Detail               = ''
  }
}

function Write-Banner {
  param([string] $Text, [string] $Colour = 'Cyan')
  Write-Host ''
  Write-Host ('=' * 78) -ForegroundColor $Colour
  Write-Host "  $Text" -ForegroundColor $Colour
  Write-Host ('=' * 78) -ForegroundColor $Colour
}

# Runs a script against every resource group at the same time and returns one result object per
# instance. Each instance's console output is written to its own log file so the parallel runs
# do not interleave on screen.
#
# The action is passed as text rather than as a script block because a script block cannot cross
# a runspace boundary. Everything the action needs arrives in the $Context hash table, since
# $using: only works when it appears literally inside the -Parallel block.
function Invoke-ForEachInstance {
  param(
    [Parameter(Mandatory)] [string[]] $ResourceGroups,
    [Parameter(Mandatory)] [string] $Phase,
    [Parameter(Mandatory)] [string] $ActionText,
    [Parameter(Mandatory)] [hashtable] $Context
  )

  $logDirectory = $LogDirectory
  $throttle = $MaxParallel

  $ResourceGroups | ForEach-Object -ThrottleLimit $throttle -Parallel {
    $rg = $_
    $context = $using:Context
    $action = [scriptblock]::Create($using:ActionText)
    $logFile = Join-Path $using:logDirectory ("{0}-{1}.log" -f $rg, $using:Phase)

    $started = Get-Date
    try {
      # *>&1 folds every stream, including Write-Host, into the pipeline so the whole run can be
      # captured. Tee-Object writes it as it goes, so the log still holds the diagnostics when
      # the action throws part way through.
      $captured = & $action $rg $context *>&1 | Tee-Object -FilePath $logFile

      $payload = $captured |
        Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties.Name -contains 'GbpsSent' } |
        Select-Object -Last 1

      [pscustomobject]@{
        ResourceGroupName = $rg
        Succeeded         = $true
        Result            = $payload
        Error             = $null
        LogFile           = $logFile
        DurationSeconds   = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
      }
    }
    catch {
      $_ | Out-File -LiteralPath $logFile -Encoding utf8 -Append

      [pscustomobject]@{
        ResourceGroupName = $rg
        Succeeded         = $false
        Result            = $null
        Error             = $_.Exception.Message
        LogFile           = $logFile
        DurationSeconds   = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
      }
    }
  }
}

$context = @{
  DeployScript        = $deployScript
  TestScript          = $testScript
  ResizeScript        = $resizeScript
  Location            = $Location
  RouterOs            = $RouterOs
  SshPublicKeyPath    = $SshPublicKeyPath
  RouterAdminPassword = $RouterAdminPassword
  ParallelConnections = $ParallelConnections
  DurationSeconds     = $DurationSeconds
  # The size routers are always created on. It is deliberately never changed to the resized
  # size: every rebuild is meant to repeat the create-then-resize cycle from the start.
  RouterVmSize        = $InitialRouterVmSize
  ResizedRouterVmSize = $ResizedRouterVmSize
  ResizeTimeoutMinutes = $ResizeTimeoutMinutes
}

$deployActionText = @'
param($rg, $context)

$deployArgs = @{
  ResourceGroupName   = $rg
  Location            = $context.Location
  RouterOs            = $context.RouterOs
  SshPublicKeyPath    = $context.SshPublicKeyPath
  RouterAdminPassword = $context.RouterAdminPassword
}

if ($context.RouterVmSize) { $deployArgs.RouterVmSize = $context.RouterVmSize }

& $context.DeployScript @deployArgs
'@

$testActionText = @'
param($rg, $context)

& $context.TestScript `
  -ResourceGroupName $rg `
  -DeploymentName 'vm-ip-forwarding' `
  -ParallelConnections $context.ParallelConnections `
  -DurationSeconds $context.DurationSeconds `
  -PassThru
'@

$resizeActionText = @'
param($rg, $context)

& $context.ResizeScript `
  -ResourceGroupName $rg `
  -DeploymentName 'vm-ip-forwarding' `
  -VmSize $context.ResizedRouterVmSize `
  -TimeoutMinutes $context.ResizeTimeoutMinutes
'@

# Runs straight after any phase that creates router VMs, so every measurement is taken on the
# resized SKU and every rebuild repeats the same create-then-resize cycle. Returns $false and
# records the reason when an instance fails.
function Invoke-ResizePhase {
  param(
    [Parameter(Mandatory)] [string] $Phase,
    [Parameter(Mandatory)] [string[]] $ResourceGroups
  )

  if (-not $ResizedRouterVmSize) { return $true }

  Write-Banner "resizing every router to $ResizedRouterVmSize before measuring" 'Yellow'

  $resizeResults = Invoke-ForEachInstance -ResourceGroups $ResourceGroups -Phase $Phase -ActionText $resizeActionText -Context $context
  $allSucceeded = $true

  foreach ($resizeResult in ($resizeResults | Sort-Object ResourceGroupName)) {
    $instance = $state[$resizeResult.ResourceGroupName]

    if ($resizeResult.Succeeded) {
      $instance.RouterVmSize = $ResizedRouterVmSize
      Write-Host ("  {0} resized in {1:N0} seconds" -f $resizeResult.ResourceGroupName, $resizeResult.DurationSeconds) -ForegroundColor Green
    }
    else {
      $allSucceeded = $false
      $instance.Status = 'resize failed'
      $instance.Detail = $resizeResult.Error
      Write-Host ("  {0} FAILED to resize: {1}" -f $resizeResult.ResourceGroupName, $resizeResult.Error) -ForegroundColor Red
      if (-not $script:failureReason) {
        $script:failureReason = "Resizing the router in '$($resizeResult.ResourceGroupName)' to $ResizedRouterVmSize failed - $($resizeResult.Error). See $($resizeResult.LogFile)."
      }
    }
  }

  return $allSucceeded
}

# Deleting the VM leaves the NIC in place, which matters: the router keeps the static address
# the route tables point at. The OS disk is not deleted with the VM, so it is removed explicitly
# to avoid leaking a disk on every rebuild. Re-running the deployment recreates the VM and
# re-applies the guest configuration that enables forwarding.
$recreateActionText = @'
param($rg, $context)

$routerVm = az deployment group show --resource-group $rg --name 'vm-ip-forwarding' `
  --query properties.outputs.routerVmName.value -o tsv
if ($LASTEXITCODE -ne 0 -or -not $routerVm) {
  throw "Could not resolve the router VM name in '$rg'."
}
$routerVm = $routerVm.Trim()

$osDiskId = az vm show --resource-group $rg --name $routerVm `
  --query storageProfile.osDisk.managedDisk.id -o tsv
if ($LASTEXITCODE -ne 0) {
  throw "Could not read the OS disk of '$routerVm' in '$rg'."
}

Write-Host "Deleting router VM '$routerVm' in '$rg'..."
az vm delete --resource-group $rg --name $routerVm --yes --only-show-errors | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "Deleting '$routerVm' in '$rg' failed with exit code $LASTEXITCODE."
}

if ($osDiskId) {
  az disk delete --ids $osDiskId.Trim() --yes --only-show-errors | Out-Null
}

Write-Host "Recreating router VM '$routerVm' in '$rg'..."

$deployArgs = @{
  ResourceGroupName   = $rg
  Location            = $context.Location
  RouterOs            = $context.RouterOs
  SshPublicKeyPath    = $context.SshPublicKeyPath
  RouterAdminPassword = $context.RouterAdminPassword
}

# Routers are always recreated on the initial size, so the resize phase that follows repeats the
# same create-then-resize cycle the initial deployment went through.
if ($context.RouterVmSize) { $deployArgs.RouterVmSize = $context.RouterVmSize }

& $context.DeployScript @deployArgs
'@

Write-Banner "fleet forwarding test over $InstanceCount instances"
Write-Host "  resource groups        : $($resourceGroups -join ', ')"
Write-Host "  location               : $Location"
Write-Host "  router OS              : $RouterOs"
if ($InitialRouterVmSize) {
  Write-Host "  router size            : $InitialRouterVmSize"
}
if ($ResizedRouterVmSize) {
  Write-Host "  resize to              : $ResizedRouterVmSize as soon as a router is created"
}
Write-Host "  test                   : $ParallelConnections streams for $DurationSeconds seconds"
Write-Host "  acceptance             : at least $ThresholdPercent% of each instance baseline"
Write-Host "  router rebuild every   : $IterationsBeforeRecreate successful iterations"
Write-Host ("  iterations             : {0}" -f $(if ($MaxIterations -gt 0) { $MaxIterations } else { 'until a failure' }))
Write-Host "  logs                   : $LogDirectory"

$failureReason = $null

try {
  if (-not $SkipDeploy) {
    Wait-ForPendingDeletes -Names $resourceGroups

    Write-Banner 'deploying all instances in parallel'
    $deployResults = Invoke-ForEachInstance -ResourceGroups $resourceGroups -Phase 'deploy' -ActionText $deployActionText -Context $context

    foreach ($deployResult in $deployResults) {
      if ($deployResult.Succeeded) {
        Write-Host ("  {0} deployed in {1:N0} seconds" -f $deployResult.ResourceGroupName, $deployResult.DurationSeconds) -ForegroundColor Green
      }
      else {
        Write-Host ("  {0} failed to deploy: {1}" -f $deployResult.ResourceGroupName, $deployResult.Error) -ForegroundColor Red
        $state[$deployResult.ResourceGroupName].Status = 'deploy failed'
        $state[$deployResult.ResourceGroupName].Detail = $deployResult.Error
        $failureReason = "Deployment of '$($deployResult.ResourceGroupName)' failed: $($deployResult.Error)"
      }
    }

    if (-not $failureReason) {
      Invoke-ResizePhase -Phase 'resize-deploy' -ResourceGroups $resourceGroups | Out-Null
    }
  }
  else {
    Write-Host ''
    Write-Host 'Skipping deployment, using the existing resource groups.' -ForegroundColor Yellow

    # Idempotent: routers already on the target size are left alone. This keeps a -SkipDeploy run
    # measuring the same size a full run would.
    Invoke-ResizePhase -Phase 'resize-deploy' -ResourceGroups $resourceGroups | Out-Null
  }

  $iteration = 0
  $successStreak = 0

  while (-not $failureReason) {
    $iteration++

    Write-Banner "iteration $iteration across $InstanceCount instances"

    $testResults = Invoke-ForEachInstance -ResourceGroups $resourceGroups -Phase "test-$iteration" -ActionText $testActionText -Context $context

    foreach ($testResult in ($testResults | Sort-Object ResourceGroupName)) {
      $instance = $state[$testResult.ResourceGroupName]
      $instance.Iterations++

      if (-not $testResult.Succeeded) {
        $instance.Status = 'test failed'
        $instance.Detail = $testResult.Error
        Write-Host ("  {0}  FAILED  {1}" -f $testResult.ResourceGroupName, $testResult.Error) -ForegroundColor Red
        if (-not $failureReason) {
          $failureReason = "Iteration ${iteration}: '$($testResult.ResourceGroupName)' failed the connectivity test - $($testResult.Error). See $($testResult.LogFile)."
        }
        continue
      }

      if (-not $testResult.Result) {
        $instance.Status = 'no result'
        $instance.Detail = 'the connectivity test returned no measurement'
        Write-Host ("  {0}  FAILED  no measurement returned" -f $testResult.ResourceGroupName) -ForegroundColor Red
        if (-not $failureReason) {
          $failureReason = "Iteration ${iteration}: '$($testResult.ResourceGroupName)' returned no measurement. See $($testResult.LogFile)."
        }
        continue
      }

      $gbps = [double]$testResult.Result.GbpsSent
      $instance.LastGbps = [math]::Round($gbps, 3)

      if ($instance.BaselineGbps -le 0) {
        $instance.BaselineGbps = [math]::Round($gbps, 3)
        $instance.Status = 'baseline'
        $instance.Detail = "first hop $($testResult.Result.FirstHop)"
        Write-Host ("  {0}  baseline {1:N2} Gbits/sec, first hop {2}" -f $testResult.ResourceGroupName, $gbps, $testResult.Result.FirstHop) -ForegroundColor Cyan
        continue
      }

      $percent = $gbps / $instance.BaselineGbps * 100.0

      if ($gbps -lt ($instance.BaselineGbps * ($ThresholdPercent / 100.0))) {
        $instance.Status = 'below threshold'
        $instance.Detail = '{0:N2} Gbits/sec is {1:N1}% of the {2:N2} Gbits/sec baseline' -f $gbps, $percent, $instance.BaselineGbps
        Write-Host ("  {0}  FAILED  {1}" -f $testResult.ResourceGroupName, $instance.Detail) -ForegroundColor Red
        if (-not $failureReason) {
          $failureReason = "Iteration ${iteration}: '$($testResult.ResourceGroupName)' dropped to $($instance.Detail)."
        }
        continue
      }

      $instance.Status = 'acceptable'
      $instance.Detail = 'first hop {0}, {1:N0} retransmits' -f $testResult.Result.FirstHop, $testResult.Result.Retransmits
      Write-Host ("  {0}  {1,8:N2} Gbits/sec  {2,6:N1}% of baseline" -f $testResult.ResourceGroupName, $gbps, $percent) -ForegroundColor Green
    }

    if ($failureReason) { break }

    $successStreak++

    if ($MaxIterations -gt 0 -and $iteration -ge $MaxIterations) {
      Write-Host ''
      Write-Host "Reached the requested iteration count of $MaxIterations." -ForegroundColor Cyan
      break
    }

    if ($successStreak -ge $IterationsBeforeRecreate) {
      $successStreak = 0

      Write-Banner "rebuilding the router VM in every instance after $IterationsBeforeRecreate successful iterations" 'Yellow'

      $recreateResults = Invoke-ForEachInstance -ResourceGroups $resourceGroups -Phase "recreate-$iteration" -ActionText $recreateActionText -Context $context

      foreach ($recreateResult in ($recreateResults | Sort-Object ResourceGroupName)) {
        $instance = $state[$recreateResult.ResourceGroupName]

        if ($recreateResult.Succeeded) {
          $instance.RouterRebuilds++
          # The rebuild put the router back on the initial size; the resize phase below moves it
          # to the target size again before the next iteration measures anything.
          if ($InitialRouterVmSize) { $instance.RouterVmSize = $InitialRouterVmSize }
          Write-Host ("  {0} router rebuilt in {1:N0} seconds" -f $recreateResult.ResourceGroupName, $recreateResult.DurationSeconds) -ForegroundColor Green
        }
        else {
          $instance.Status = 'rebuild failed'
          $instance.Detail = $recreateResult.Error
          Write-Host ("  {0} FAILED to rebuild the router: {1}" -f $recreateResult.ResourceGroupName, $recreateResult.Error) -ForegroundColor Red
          if (-not $failureReason) {
            $failureReason = "Iteration ${iteration}: rebuilding the router in '$($recreateResult.ResourceGroupName)' failed - $($recreateResult.Error). See $($recreateResult.LogFile)."
          }
        }
      }

      if ($failureReason) { break }

      Invoke-ResizePhase -Phase "resize-$iteration" -ResourceGroups $resourceGroups | Out-Null
    }
  }
}
finally {
  Write-Banner 'fleet run summary'

  $state.Values |
    Select-Object ResourceGroupName, RouterVmSize, BaselineGbps, LastGbps, Iterations, RouterRebuilds, Status, Detail |
    Format-Table -AutoSize | Out-String -Width 220 | Write-Host

  $summaryCsv = Join-Path $LogDirectory 'summary.csv'
  $state.Values | Export-Csv -LiteralPath $summaryCsv -NoTypeInformation
  Write-Host "Per-instance results written to $summaryCsv"
  Write-Host "Full per-iteration logs are in $LogDirectory"

  if ($DeleteResourceGroupsOnExit) {
    Write-Host ''
    Write-Host 'Deleting the resource groups...' -ForegroundColor Yellow
    foreach ($rg in $resourceGroups) {
      az group delete --name $rg --yes --no-wait --only-show-errors | Out-Null
    }
    Write-Host '  deletion started, running in the background.'
  }
}

if ($failureReason) {
  Write-Host ''
  Write-Host "STOPPED: $failureReason" -ForegroundColor Red
  exit 1
}

Write-Host ''
Write-Host 'Every instance stayed within the acceptable throughput range.' -ForegroundColor Green
