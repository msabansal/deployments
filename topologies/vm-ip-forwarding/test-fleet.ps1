<#
.SYNOPSIS
  Runs test-redeploy-loop.ps1 against several resource groups in parallel and monitors them.

.DESCRIPTION
  Creates N resource group names from a prefix - "<prefix>-01" .. "<prefix>-NN" - and starts one
  test-redeploy-loop.ps1 per resource group. That script owns everything that happens to its
  instance: deploying the topology, resizing the router, running the connectivity test, and
  redeploying or rebuilding the router VM between iterations.

  This script only launches and monitors. It does not stage the work, so instances never wait
  for each other: a slow deployment in one resource group does not hold up testing in another,
  and an instance that is mid-rebuild does not stop its neighbours from measuring. The only
  thing shared between them is an abort flag, which the first instance to fail sets so the
  others stop at their next iteration boundary.

  Each instance writes its full output to its own log file and returns a result object. The
  per-instance result table is printed when the run ends, and the script exits with code 1 if
  any instance failed.

.EXAMPLE
  .\test-fleet.ps1 -ResourceGroupPrefix sabansal-fwd -Location westus2 -InstanceCount 4

.EXAMPLE
  .\test-fleet.ps1 -ResourceGroupPrefix sabansal-fwd -Location westus2 -InstanceCount 4 `
    -IterationsBeforeChange 5 -MaxIterations 50 -SkipDeploy

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

  # What happens to a router VM between iterations, and how often.
  [ValidateSet('Redeploy', 'Recreate', 'None')]
  [string] $RouterChange = 'Recreate',

  [ValidateRange(1, 1000)]
  [int] $IterationsBeforeChange = 3,

  # 0 means keep going until an instance fails.
  [ValidateRange(0, 10000)]
  [int] $MaxIterations = 0,

  [ValidateSet('AzureLinux', 'WindowsServer2022')]
  [string] $RouterOs = 'AzureLinux',

  [string] $SshPublicKeyPath = '~\.ssh\id_ed25519.pub',

  [securestring] $RouterAdminPassword,

  # The SKU router VMs are created on, both by the initial deployment and by a Recreate.
  [string] $InitialRouterVmSize,

  # When set, a router is resized to this SKU as soon as it is created, before anything is
  # measured against it.
  [string] $ResizedRouterVmSize,

  [ValidateRange(1, 120)]
  [int] $RouterTimeoutMinutes = 20,

  [ValidateRange(1, 128)]
  [int] $ParallelConnections = 8,

  [ValidateRange(5, 3600)]
  [int] $DurationSeconds = 60,

  # Throughput floor for iterations after the first, as a percentage of the instance baseline.
  [ValidateRange(1, 100)]
  [int] $ThresholdPercent = 80,

  # An absolute floor applied to every instance, independent of its baseline.
  [ValidateRange(0, 100000)]
  [double] $MinimumMbps = 100,

  # How often each instance prints a progress summary and flushes its results to disk.
  [ValidateRange(0, 10000)]
  [int] $SummaryEveryIterations = 10,

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

$loopScript = Join-Path $PSScriptRoot 'test-redeploy-loop.ps1'
if (-not (Test-Path -LiteralPath $loopScript -PathType Leaf)) {
  throw 'Could not find test-redeploy-loop.ps1 next to this script.'
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

# Prompting once here keeps parallel instances from racing on the same console prompt.
if ($RouterOs -eq 'WindowsServer2022' -and -not $SkipDeploy -and -not $RouterAdminPassword) {
  $RouterAdminPassword = Read-Host -AsSecureString -Prompt 'Administrator password for the Windows router VMs'
}

if (-not $LogDirectory) {
  $LogDirectory = Join-Path $PSScriptRoot ('fleet-logs-{0:yyyyMMdd-HHmmss}' -f (Get-Date))
}
New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null

if ($MaxParallel -le 0) { $MaxParallel = $InstanceCount }

$resourceGroups = 1..$InstanceCount | ForEach-Object { '{0}-{1:d2}' -f $ResourceGroupPrefix, $_ }

# Shared across every runspace. A ConcurrentDictionary is passed by reference, so an instance
# that fails can flip the abort flag and the others see it at their next boundary. TryAdd keeps
# the first failure, which is the one worth reporting.
$shared = [System.Collections.Concurrent.ConcurrentDictionary[string, object]]::new()
$shared['abort'] = $false

$context = @{
  LoopScript             = $loopScript
  LogDirectory           = $LogDirectory
  Location               = $Location
  RouterOs               = $RouterOs
  SshPublicKeyPath       = $SshPublicKeyPath
  RouterAdminPassword    = $RouterAdminPassword
  RouterChange           = $RouterChange
  IterationsBeforeChange = $IterationsBeforeChange
  MaxIterations          = $MaxIterations
  InitialRouterVmSize    = $InitialRouterVmSize
  ResizedRouterVmSize    = $ResizedRouterVmSize
  RouterTimeoutMinutes   = $RouterTimeoutMinutes
  ParallelConnections    = $ParallelConnections
  DurationSeconds        = $DurationSeconds
  ThresholdPercent       = $ThresholdPercent
  MinimumMbps            = $MinimumMbps
  SummaryEveryIterations = $SummaryEveryIterations
  BaselineGbps           = $BaselineGbps
  Deploy                 = -not $SkipDeploy
  Shared                 = $shared
}

Write-Host ''
Write-Host ('=' * 78) -ForegroundColor Cyan
Write-Host "  fleet forwarding test over $InstanceCount instances" -ForegroundColor Cyan
Write-Host ('=' * 78) -ForegroundColor Cyan
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
if ($MinimumMbps -gt 0) { Write-Host ("  minimum                : {0:N0} Mbits/sec regardless of the baseline" -f $MinimumMbps) }
Write-Host ("  router change          : {0}" -f $(if ($RouterChange -eq 'None') { 'none' } else { "$RouterChange every $IterationsBeforeChange successful iterations" }))
Write-Host ("  iterations             : {0}" -f $(if ($MaxIterations -gt 0) { $MaxIterations } else { 'until a failure' }))
Write-Host "  concurrency            : $MaxParallel instances at a time"
Write-Host "  logs                   : $LogDirectory"
Write-Host ''
Write-Host 'Each instance runs test-redeploy-loop.ps1 end to end and independently of the others.'
Write-Host 'Console lines are prefixed with the resource group and will interleave.'
Write-Host ''

$results = New-Object System.Collections.Generic.List[object]

$resourceGroups | ForEach-Object -ThrottleLimit $MaxParallel -Parallel {
  $rg = $_
  $context = $using:context
  $logFile = Join-Path $context.LogDirectory "$rg.log"
  $started = Get-Date

  # An instance that has not started yet is skipped outright once another one has failed, so a
  # failing fleet is not left deploying resource groups nobody will look at.
  if ($context.Shared['abort']) {
    return [pscustomobject]@{
      ResourceGroupName = $rg
      RouterVmSize      = $null
      BaselineGbps      = $null
      LastGbps          = $null
      Iterations        = 0
      RouterChanges     = 0
      Status            = 'skipped'
      Detail            = 'another instance failed before this one started'
      Succeeded         = $false
      DurationSeconds   = 0
      LogFile           = $logFile
    }
  }

  $loopArgs = @{
    ResourceGroupName      = $rg
    Location               = $context.Location
    RouterOs               = $context.RouterOs
    SshPublicKeyPath       = $context.SshPublicKeyPath
    RouterAdminPassword    = $context.RouterAdminPassword
    RouterChange           = $context.RouterChange
    IterationsBeforeChange = $context.IterationsBeforeChange
    MaxIterations          = $context.MaxIterations
    RouterTimeoutMinutes   = $context.RouterTimeoutMinutes
    ParallelConnections    = $context.ParallelConnections
    DurationSeconds        = $context.DurationSeconds
    ThresholdPercent       = $context.ThresholdPercent
    MinimumMbps            = $context.MinimumMbps
    SummaryEveryIterations = $context.SummaryEveryIterations
    BaselineGbps           = $context.BaselineGbps
    LogPrefix              = $rg
    # Give each instance its own CSV next to its log, so the periodic flush has somewhere to write
    # and a long fleet run leaves per-iteration results behind even if it is interrupted.
    ResultCsvPath          = (Join-Path $context.LogDirectory "$rg.csv")
    AbortSignal            = $context.Shared
    PassThru               = $true
  }

  if ($context.Deploy) { $loopArgs.Deploy = $true }
  if ($context.InitialRouterVmSize) { $loopArgs.InitialRouterVmSize = $context.InitialRouterVmSize }
  if ($context.ResizedRouterVmSize) { $loopArgs.ResizedRouterVmSize = $context.ResizedRouterVmSize }

  try {
    # *>&1 folds every stream, including Write-Host, into the pipeline so the whole run can be
    # captured. Tee-Object writes it as it goes, so the log still holds the diagnostics when the
    # instance throws part way through, and the final ForEach-Object re-emits each item to the
    # console as it arrives. Assigning the pipeline to a variable instead would send the whole run
    # to the log and leave the console silent until every instance had finished.
    $summary = $null

    & $context.LoopScript @loopArgs *>&1 | Tee-Object -FilePath $logFile | ForEach-Object {
      if ($_ -is [pscustomobject] -and $_.PSObject.Properties.Name -contains 'Succeeded') {
        $summary = $_
        return
      }

      if ($_ -is [System.Management.Automation.InformationRecord]) {
        # Write-Host arrives here as an InformationRecord. Unwrap it so the console shows the text
        # rather than the record type, and keep the colour the instance chose.
        $message = $_.MessageData

        if ($message -is [System.Management.Automation.HostInformationMessage] -and $message.ForegroundColor) {
          Write-Host $message.Message -ForegroundColor $message.ForegroundColor
        }
        else {
          Write-Host ([string]$message)
        }
      }
      elseif ($_ -is [System.Management.Automation.ErrorRecord]) {
        Write-Host "[$rg] $($_.Exception.Message)" -ForegroundColor Red
      }
      elseif ($_ -is [System.Management.Automation.WarningRecord]) {
        Write-Host "[$rg] $($_.Message)" -ForegroundColor Yellow
      }
      else {
        $text = ($_ | Out-String).TrimEnd()
        if ($text) { Write-Host $text }
      }
    }

    if (-not $summary) {
      $context.Shared.TryAdd('failureReason', "'$rg' returned no result (see $logFile)") | Out-Null
      $context.Shared['abort'] = $true

      return [pscustomobject]@{
        ResourceGroupName = $rg
        RouterVmSize      = $null
        BaselineGbps      = $null
        LastGbps          = $null
        Iterations        = 0
        RouterChanges     = 0
        Status            = 'no result'
        Detail            = 'the instance returned no result object'
        Succeeded         = $false
        DurationSeconds   = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
        LogFile           = $logFile
      }
    }

    if (-not $summary.Succeeded) {
      $context.Shared.TryAdd('failureReason', "'$rg': $($summary.Detail) (see $logFile)") | Out-Null
      $context.Shared['abort'] = $true
    }

    return [pscustomobject]@{
      ResourceGroupName = $summary.ResourceGroupName
      RouterVmSize      = $summary.RouterVmSize
      BaselineGbps      = $summary.BaselineGbps
      LastGbps          = $summary.LastGbps
      Iterations        = $summary.Iterations
      RouterChanges     = $summary.RouterChanges
      Status            = $summary.Status
      Detail            = $summary.Detail
      Succeeded         = $summary.Succeeded
      DurationSeconds   = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
      LogFile           = $logFile
    }
  }
  catch {
    $_ | Out-File -LiteralPath $logFile -Encoding utf8 -Append
    Write-Host "[$rg] $($_.Exception.Message)" -ForegroundColor Red
    $context.Shared.TryAdd('failureReason', "'$rg': $($_.Exception.Message) (see $logFile)") | Out-Null
    $context.Shared['abort'] = $true

    return [pscustomobject]@{
      ResourceGroupName = $rg
      RouterVmSize      = $null
      BaselineGbps      = $null
      LastGbps          = $null
      Iterations        = 0
      RouterChanges     = 0
      Status            = 'error'
      Detail            = $_.Exception.Message
      Succeeded         = $false
      DurationSeconds   = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
      LogFile           = $logFile
    }
  }
} | ForEach-Object { $results.Add($_) }

$failureReason = $null
$shared.TryGetValue('failureReason', [ref] $failureReason) | Out-Null

Write-Host ''
Write-Host ('=' * 78) -ForegroundColor Cyan
Write-Host '  fleet run summary' -ForegroundColor Cyan
Write-Host ('=' * 78) -ForegroundColor Cyan

$results |
  Sort-Object ResourceGroupName |
  Select-Object ResourceGroupName, RouterVmSize, BaselineGbps, LastGbps, Iterations, RouterChanges, Status, Detail |
  Format-Table -AutoSize | Out-String -Width 220 | Write-Host

$summaryCsv = Join-Path $LogDirectory 'summary.csv'
$results | Sort-Object ResourceGroupName | Export-Csv -LiteralPath $summaryCsv -NoTypeInformation
Write-Host "Per-instance results written to $summaryCsv"
Write-Host "Full per-instance logs are in $LogDirectory"

if ($DeleteResourceGroupsOnExit) {
  Write-Host ''
  Write-Host 'Deleting the resource groups...' -ForegroundColor Yellow
  foreach ($rg in $resourceGroups) {
    az group delete --name $rg --yes --no-wait --only-show-errors | Out-Null
  }
  Write-Host '  deletion started, running in the background.'
}

if ($failureReason) {
  Write-Host ''
  Write-Host "STOPPED: $failureReason" -ForegroundColor Red
  exit 1
}

Write-Host ''
Write-Host 'Every instance stayed within the acceptable throughput range.' -ForegroundColor Green
