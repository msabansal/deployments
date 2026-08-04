<#
.SYNOPSIS
  Repeatedly redeploys the router VM and re-runs the throughput test, stopping as soon as the
  throughput drops below an acceptable fraction of the baseline.

.DESCRIPTION
  Each iteration runs test-connectivity.ps1 and compares the measured throughput against a
  baseline. The baseline is either supplied with -BaselineGbps or taken from the first
  iteration. While the throughput stays at or above -ThresholdPercent of the baseline the
  router VM is redeployed onto a different host and the test runs again. The loop stops on the
  first iteration that falls below the threshold, which is the result you want to capture: it
  identifies a host or a placement that cannot sustain the expected forwarding rate.

  The path check inside test-connectivity.ps1 also gates every iteration, so a run that
  silently stopped traversing the router is reported as a failure rather than as throughput.

.EXAMPLE
  .\test-redeploy-loop.ps1 -ResourceGroupName sabansal-rg-fwd

.EXAMPLE
  .\test-redeploy-loop.ps1 -ResourceGroupName sabansal-rg-fwd -BaselineGbps 7.43 -MaxIterations 20
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $ResourceGroupName,

  [string] $DeploymentName = 'vm-ip-forwarding',

  # Throughput in Gbits/sec that later iterations are measured against. When left at 0 the
  # first iteration establishes the baseline.
  [ValidateRange(0, 1000)]
  [double] $BaselineGbps = 0,

  [ValidateRange(1, 100)]
  [int] $ThresholdPercent = 80,

  # 0 means keep going until an iteration fails.
  [ValidateRange(0, 1000)]
  [int] $MaxIterations = 0,

  [ValidateRange(1, 128)]
  [int] $ParallelConnections = 8,

  [ValidateRange(5, 3600)]
  [int] $DurationSeconds = 60,

  [int] $Port = 5201,

  [switch] $Reverse,

  # When set together with -ResizedRouterVmSize, each iteration puts the router back on this SKU
  # before resizing it up again, so every run repeats the same size cycle.
  [string] $InitialRouterVmSize,

  # When set, the router is moved to this SKU before every run, so throughput is always measured
  # on it. Combined with -InitialRouterVmSize this replaces the plain redeploy with a full
  # downsize-then-upsize cycle.
  [string] $ResizedRouterVmSize,

  # Minutes to wait for the router VM to come back after a redeploy.
  [ValidateRange(1, 120)]
  [int] $RedeployTimeoutMinutes = 20,

  # Written as CSV when set, so a long run can be inspected afterwards.
  [string] $ResultCsvPath
)

$ErrorActionPreference = 'Stop'

$testScript = Join-Path $PSScriptRoot 'test-connectivity.ps1'
if (-not (Test-Path -LiteralPath $testScript)) {
  throw "Could not find test-connectivity.ps1 next to this script."
}

$resizeScript = Join-Path $PSScriptRoot 'resize-router.ps1'
$cycleSizes = @($InitialRouterVmSize, $ResizedRouterVmSize) | Where-Object { $_ }

if ($cycleSizes -and -not (Test-Path -LiteralPath $resizeScript)) {
  throw "Could not find resize-router.ps1 next to this script."
}

if ($InitialRouterVmSize -and $InitialRouterVmSize -eq $ResizedRouterVmSize) {
  throw 'InitialRouterVmSize and ResizedRouterVmSize are the same, so there is nothing to cycle.'
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

function Invoke-RouterRedeploy {
  param([Parameter(Mandatory)] [string] $VmName)

  Write-Host "Redeploying the router VM '$VmName' onto a different host..." -ForegroundColor Yellow

  az vm redeploy --resource-group $ResourceGroupName --name $VmName --only-show-errors | Out-Null

  if ($LASTEXITCODE -ne 0) {
    throw "Redeploy of '$VmName' failed with exit code $LASTEXITCODE."
  }

  Wait-VmReady -VmName $VmName -TimeoutMinutes $RedeployTimeoutMinutes
  Write-Host "  router VM is running again." -ForegroundColor Green
}

$routerVmName = Get-RouterVmName
$threshold = $ThresholdPercent / 100.0
$results = New-Object System.Collections.Generic.List[object]
$iteration = 0
$failureReason = $null

# Puts the router through the configured size cycle. Each step is a no-op when the VM already
# runs that size, so the function is safe to call before every iteration.
function Invoke-RouterSizeCycle {
  foreach ($size in $cycleSizes) {
    & $resizeScript `
      -ResourceGroupName $ResourceGroupName `
      -DeploymentName $DeploymentName `
      -VmName $routerVmName `
      -VmSize $size `
      -TimeoutMinutes $RedeployTimeoutMinutes
  }
}

Write-Host ''
Write-Host '########## continuous forwarding throughput test ##########' -ForegroundColor Cyan
Write-Host "  resource group : $ResourceGroupName"
Write-Host "  router VM      : $routerVmName"
Write-Host "  acceptance     : at least $ThresholdPercent% of the baseline"
if ($cycleSizes) {
  Write-Host "  size cycle     : $($cycleSizes -join ' -> ') before every iteration"
}
if ($BaselineGbps -gt 0) {
  Write-Host ("  baseline       : {0:N2} Gbits/sec (supplied)" -f $BaselineGbps)
}
else {
  Write-Host '  baseline       : measured by the first iteration'
}
Write-Host ("  iterations     : {0}" -f $(if ($MaxIterations -gt 0) { $MaxIterations } else { 'until a failure' }))
Write-Host '##########################################################' -ForegroundColor Cyan

while ($true) {
  $iteration++

  Write-Host ''
  Write-Host "---------- iteration $iteration ----------" -ForegroundColor Cyan

  if ($iteration -gt 1 -or $cycleSizes) {
    try {
      if ($cycleSizes) {
        # The size cycle already deallocates and restarts the VM, which also lands it on a new
        # host, so it replaces the redeploy rather than being stacked on top of it. It runs
        # before the first iteration too, so every measurement is taken on the same size.
        Invoke-RouterSizeCycle
      }
      else {
        Invoke-RouterRedeploy -VmName $routerVmName
      }
    }
    catch {
      $failureReason = "Iteration ${iteration}: $($_.Exception.Message)"
      $results.Add([pscustomobject]@{
          Iteration    = $iteration
          GbpsSent     = $null
          PercentOfBaseline = $null
          Status       = 'router change failed'
          Detail       = $_.Exception.Message
          TimestampUtc = (Get-Date).ToUniversalTime()
        })
      break
    }
  }

  try {
    $result = & $testScript `
      -ResourceGroupName $ResourceGroupName `
      -DeploymentName $DeploymentName `
      -ParallelConnections $ParallelConnections `
      -DurationSeconds $DurationSeconds `
      -Port $Port `
      -Reverse:$Reverse `
      -PassThru
  }
  catch {
    $failureReason = "Iteration ${iteration}: the throughput test failed - $($_.Exception.Message)"
    $results.Add([pscustomobject]@{
        Iteration    = $iteration
        GbpsSent     = $null
        PercentOfBaseline = $null
        Status       = 'test failed'
        Detail       = $_.Exception.Message
        TimestampUtc = (Get-Date).ToUniversalTime()
      })
    break
  }

  if (-not $result) {
    $failureReason = "Iteration ${iteration}: the throughput test returned no result."
    break
  }

  if ($BaselineGbps -le 0) {
    $BaselineGbps = $result.GbpsSent
    Write-Host ''
    Write-Host ("Baseline established at {0:N2} Gbits/sec. Later iterations must reach {1:N2} Gbits/sec." -f $BaselineGbps, ($BaselineGbps * $threshold)) -ForegroundColor Cyan
  }

  $percent = if ($BaselineGbps -gt 0) { $result.GbpsSent / $BaselineGbps * 100.0 } else { 0 }
  $acceptable = $result.GbpsSent -ge ($BaselineGbps * $threshold)

  $results.Add([pscustomobject]@{
      Iteration         = $iteration
      GbpsSent          = [math]::Round($result.GbpsSent, 3)
      PercentOfBaseline = [math]::Round($percent, 1)
      Status            = $(if ($acceptable) { 'acceptable' } else { 'below threshold' })
      Detail            = "first hop $($result.FirstHop), $($result.Retransmits) retransmits"
      TimestampUtc      = $result.TimestampUtc
    })

  if (-not $acceptable) {
    $failureReason = "Iteration ${iteration}: throughput was {0:N2} Gbits/sec, only {1:N1}% of the {2:N2} Gbits/sec baseline." -f $result.GbpsSent, $percent, $BaselineGbps
    Write-Host ''
    Write-Host $failureReason -ForegroundColor Red
    break
  }

  Write-Host ''
  Write-Host ("Iteration $iteration is acceptable: {0:N2} Gbits/sec, {1:N1}% of the baseline." -f $result.GbpsSent, $percent) -ForegroundColor Green

  if ($MaxIterations -gt 0 -and $iteration -ge $MaxIterations) {
    Write-Host ''
    Write-Host "Reached the requested iteration count of $MaxIterations." -ForegroundColor Cyan
    break
  }
}

Write-Host ''
Write-Host '################## run summary ##################' -ForegroundColor Cyan
Write-Host ("  baseline   : {0:N2} Gbits/sec" -f $BaselineGbps)
Write-Host ("  threshold  : {0:N2} Gbits/sec ({1}%)" -f ($BaselineGbps * $threshold), $ThresholdPercent)
Write-Host ("  iterations : {0}" -f $results.Count)
Write-Host ''

$results | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

if ($ResultCsvPath) {
  $results | Export-Csv -LiteralPath $ResultCsvPath -NoTypeInformation
  Write-Host "Results written to $ResultCsvPath"
}

Write-Host '#################################################' -ForegroundColor Cyan

if ($failureReason) {
  Write-Host ''
  Write-Host "STOPPED: $failureReason" -ForegroundColor Red
  exit 1
}

Write-Host ''
Write-Host 'All iterations stayed within the acceptable throughput range.' -ForegroundColor Green
