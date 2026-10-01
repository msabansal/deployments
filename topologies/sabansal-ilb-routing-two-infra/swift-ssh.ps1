function Write-Log {
  param(
    [Parameter(Mandatory)]
    [ValidateSet('STEP', 'INFO', 'SUCCESS', 'WARN', 'ERROR', 'REMOTE')]
    [string] $Level,

    [Parameter(Mandatory)]
    [string] $Message
  )

  $color = switch ($Level) {
    'STEP' { 'Cyan' }
    'SUCCESS' { 'Green' }
    'WARN' { 'Yellow' }
    'ERROR' { 'Red' }
    'REMOTE' { 'DarkGray' }
    default { 'Gray' }
  }
  $timestamp = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fffK'
  Write-Host "$timestamp [$Level] $Message" -ForegroundColor $color
}

function Resolve-RequiredFile {
  param([Parameter(Mandatory)][string] $Path)
  $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
  if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
    throw "Required file was not found: $resolved"
  }
  return $resolved
}

function Assert-LastExitCode {
  param([Parameter(Mandatory)][string] $Operation)
  if ($LASTEXITCODE -ne 0) {
    throw "$Operation failed with exit code $LASTEXITCODE."
  }

  Write-Log -Level SUCCESS -Message "$Operation completed."
}

function Invoke-ResilientSshCommand {
  param(
    [Parameter(Mandatory)] [string] $HostAddress,
    [Parameter(Mandatory)] [string] $Command,
    [Parameter(Mandatory)] [string] $OperationName,
    [ValidateRange(30, 86400)] [int] $TimeoutSeconds = 300,
    [AllowEmptyCollection()] [Collections.Generic.List[string]] $CapturedOutput
  )

  $operationId = [Guid]::NewGuid().ToString('N')
  $unitName = "swift-ilb-$operationId"
  $scriptPath = "/tmp/$unitName.sh"
  $logPath = "/tmp/$unitName.log"
  $statusPath = "/tmp/$unitName.status"
  $statusMarker = '__SWIFT_EXIT_CODE__='
  $lineMarker = "__SWIFT_LOG_${operationId}__="
  $timeoutMarker = "__SWIFT_TIMEOUT_${operationId}__"
  $remoteScript = @"
#!/bin/bash
sleep 2
(
$Command
) > '$logPath' 2>&1
exit_code=`$?
printf '%s\n' "`$exit_code" > '$statusPath.tmp'
mv '$statusPath.tmp' '$statusPath'
"@
  $scriptBytes = [Text.Encoding]::UTF8.GetBytes(($remoteScript -replace "`r`n", "`n"))
  $encodedScript = [Convert]::ToBase64String($scriptBytes)
  $scriptHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($scriptBytes)).ToLowerInvariant()
  $runCommand = "sudo systemd-run --quiet --no-block --unit '$unitName'"
  $launchCommand = @(
    'set -o pipefail'
    "sudo rm -f '$scriptPath' '$logPath' '$statusPath' '$statusPath.tmp'"
    "sudo install -m 0700 /dev/null '$scriptPath'"
    "tr -d '\r\n' | base64 -d | sudo tee '$scriptPath' >/dev/null"
    "test `"`$(sudo sha256sum '$scriptPath' | awk '{print `$1}')`" = '$scriptHash'"
    "sudo chmod 0700 '$scriptPath'"
    "if test -e /sys/fs/selinux/enforce; then context=`$(sudo id -Z) && $runCommand --property=`"SELinuxContext=`$context`" /bin/bash '$scriptPath'; else $runCommand /bin/bash '$scriptPath'; fi"
  ) -join ' && '

  Write-Log -Level INFO -Message "Starting $OperationName as detached systemd unit '$unitName'."
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $attempt = 0
  $reportedInterruption = $false
  $operationComplete = $false
  $progress = [pscustomobject]@{ Offset = 0; ExitCode = $null; TimedOut = $false; Error = $null }
  $outputLines = $CapturedOutput
  if ($null -eq $outputLines) { $outputLines = [Collections.Generic.List[string]]::new() }
  $receiveLine = {
    param([string] $Text)

    if ($Text -match "^$([regex]::Escape($lineMarker))(\d+):(.*)$") {
      $lineNumber = [int]$Matches[1]
      $line = $Matches[2]
      if ($lineNumber -le $progress.Offset) { return }
      if ($lineNumber -ne $progress.Offset + 1) {
        $progress.Error = "Remote log skipped from line $($progress.Offset) to $lineNumber."
        return
      }
      $progress.Offset = $lineNumber
      [void]$outputLines.Add($line)
      Write-Log -Level REMOTE -Message "[$HostAddress] $line"
    }
    elseif ($Text -match "^$([regex]::Escape($statusMarker))(\d+)$") {
      $progress.ExitCode = [int]$Matches[1]
    }
    elseif ($Text -eq $timeoutMarker) {
      $progress.TimedOut = $true
    }
    elseif ($Text) {
      Write-Log -Level REMOTE -Message "[$HostAddress] [ssh] $Text"
    }
  }
  try {
    while ((Get-Date) -lt $deadline) {
      $attempt++
      $remainingSeconds = [int][Math]::Ceiling(($deadline - (Get-Date)).TotalSeconds)
      $monitorCommand = @"
next_line=$($progress.Offset)
deadline=`$((`$(date +%s) + $remainingSeconds))
while true; do
complete=0
if sudo test -f '$statusPath'; then complete=1; fi
log_lines=0
if sudo test -f '$logPath'; then
  if test "`$complete" -eq 1; then
    log_lines=`$(sudo awk 'END {print NR}' '$logPath')
  else
    log_lines=`$(sudo wc -l '$logPath' | awk '{print `$1}')
  fi
  if test "`$log_lines" -lt "`$next_line"; then
    echo 'Remote log was truncated unexpectedly.' >&2
    exit 1
  fi
  if test "`$log_lines" -gt "`$next_line"; then
    sudo awk -v start="`$((next_line + 1))" -v end="`$log_lines" -v prefix='$lineMarker' 'NR >= start && NR <= end {printf "%s%d:%s\n", prefix, NR, `$0}' '$logPath' || exit 1
    next_line=`$log_lines
  fi
fi
if test "`$complete" -eq 1; then
  exit_code=`$(sudo cat '$statusPath') || exit 1
  if ! (sudo systemctl is-active --quiet '$unitName-cleanup.timer' || sudo systemd-run --quiet --unit '$unitName-cleanup' --on-active=${TimeoutSeconds}s /usr/bin/rm -f '$scriptPath' '$logPath' '$statusPath' '$statusPath.tmp'); then
    echo 'Automatic diagnostic cleanup could not be scheduled; diagnostic files were retained.' >&2
  fi
  printf '$statusMarker%s\n' "`$exit_code"
  exit 0
fi
if test "`$(date +%s)" -ge "`$deadline"; then
  echo '$timeoutMarker'
  exit 124
fi
sleep 2
done
"@
      $remoteCommand = $monitorCommand -replace "`r`n", "`n"
      if ($attempt -eq 1) {
        $remoteCommand = "$launchCommand && {`n$remoteCommand`n}"
      }
      $sessionInput = if ($attempt -eq 1) { $encodedScript } else { '' }
      $sessionInput | & ssh -q -i $privateKeyPath `
        -o BatchMode=yes -o StrictHostKeyChecking=no `
        -o ConnectTimeout=10 -o ConnectionAttempts=1 `
        -o ServerAliveInterval=5 -o ServerAliveCountMax=2 `
        "azureuser@$HostAddress" $remoteCommand 2>&1 |
        ForEach-Object { & $receiveLine -Text ([string]$_) }
      $sshExitCode = $LASTEXITCODE
      if ($progress.Error) { throw "$OperationName failed: $($progress.Error)" }
      if ($null -ne $progress.ExitCode) {
        $operationComplete = $true
        if ($progress.ExitCode -ne 0) {
          throw "$OperationName failed with exit code $($progress.ExitCode)."
        }
        Write-Log -Level SUCCESS -Message "$OperationName completed using $attempt SSH session(s)."
        return ($outputLines -join "`n")
      }
      if ($progress.TimedOut) { break }
      if ($sshExitCode -ne 255) {
        throw "$OperationName SSH session ended with exit code $sshExitCode without a completion status; diagnostics remain in $logPath."
      }
      if (-not $reportedInterruption) {
        Write-Log -Level WARN -Message "SSH connectivity to $HostAddress was interrupted while $OperationName continued in the background. Reconnecting without replaying the command."
        $reportedInterruption = $true
      }
      Start-Sleep -Seconds 2
    }

    throw "$OperationName did not complete within $TimeoutSeconds seconds. Remote diagnostics remain in $logPath."
  }
  finally {
    if (-not $operationComplete) {
      $stopCommand = @"
sudo systemctl stop '$unitName'
stop_code=`$?
if sudo test -f '$logPath'; then
  sudo awk -v start="$($progress.Offset + 1)" -v prefix='$lineMarker' 'NR >= start {printf "%s%d:%s\n", prefix, NR, `$0}' '$logPath'
fi
exit "`$stop_code"
"@
      $stopOutput = @(
        & ssh -q -i $privateKeyPath `
          -o BatchMode=yes -o StrictHostKeyChecking=no `
          -o ConnectTimeout=10 -o ConnectionAttempts=1 `
          "azureuser@$HostAddress" ($stopCommand -replace "`r`n", "`n") 2>&1
      )
      $stopExitCode = $LASTEXITCODE
      foreach ($line in $stopOutput) { & $receiveLine -Text ([string]$line) }
      if ($stopExitCode -ne 0) {
        Write-Log -Level WARN -Message "Could not stop interrupted remote unit '$unitName'. Check it before retrying creation; diagnostics remain in $logPath."
      }
    }
  }
}
