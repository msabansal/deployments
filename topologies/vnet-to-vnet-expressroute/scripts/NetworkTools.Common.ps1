function Invoke-ErAzJson {
  param([Parameter(Mandatory)] [string[]] $Arguments, [string] $SubscriptionId)

  $PSNativeCommandUseErrorActionPreference = $false
  if ($SubscriptionId) { $Arguments += @('--subscription', $SubscriptionId) }
  $raw = & az @Arguments --only-show-errors --output json
  if ($LASTEXITCODE -ne 0) {
    throw "Azure CLI failed (exit $LASTEXITCODE): az $($Arguments -join ' ')"
  }
  if (-not $raw) { throw 'Azure CLI returned no JSON.' }
  ($raw -join "`n") | ConvertFrom-Json
}

function Get-ErTestVms {
  param([string] $ResourceGroupName, [string] $NamePrefix, [string] $SubscriptionId)

  foreach ($role in @('onprem', 'azure')) {
    $name = "$NamePrefix-$role-vm"
    $vm = Invoke-ErAzJson -SubscriptionId $SubscriptionId -Arguments @(
      'vm', 'show', '--resource-group', $ResourceGroupName, '--name', $name
    )
    if ($vm.name -ne $name -or $vm.storageProfile.osDisk.osType -ne 'Linux') {
      throw "Expected Linux topology VM '$name'."
    }
    $nics = @($vm.networkProfile.networkInterfaces)
    if ($nics.Count -ne 1) { throw "Expected exactly one NIC on '$name'; found $($nics.Count)." }
    $nic = Invoke-ErAzJson -SubscriptionId $SubscriptionId -Arguments @(
      'network', 'nic', 'show', '--ids', $nics[0].id
    )
    $configs = @($nic.ipConfigurations | Where-Object { $_.privateIPAddress -notmatch ':' })
    if ($configs.Count -ne 1) { throw "Expected exactly one IPv4 configuration on '$name'." }
    $config = $configs[0]
    $expectedSubnet = "/virtualNetworks/$NamePrefix-$role-vnet/subnets/workload"
    if (-not $config.subnet.id.EndsWith($expectedSubnet, [StringComparison]::OrdinalIgnoreCase)) {
      throw "'$name' is not in the expected topology workload subnet '$expectedSubnet'."
    }
    $ip = [string] $config.privateIPAddress
    $parsed = $null
    if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or
        -not [Net.IPAddress]::TryParse($ip, [ref] $parsed) -or
        $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
      throw "Invalid NIC IPv4 address for '$name': '$ip'."
    }
    [pscustomobject]@{ Name = $name; PrivateIp = $parsed.ToString(); Role = $role }
  }
}

function Invoke-ErVmScript {
  param(
    [string] $ResourceGroupName,
    [string] $SubscriptionId,
    [string] $VmName,
    [Parameter(Mandatory)] [string] $Script,
    [ValidateRange(10, 1800)] [int] $TimeoutSeconds = 180
  )

  $token = [guid]::NewGuid().ToString('N')
  $marker = "ER_EXIT_$token"
  $delimiter = "ER_SCRIPT_$token"
  # Run Command may report "succeeded" even when the shell fails. Bound both
  # output streams below its 4 KB limit and require a unique remote exit marker.
  $wrapper = @'
#!/bin/bash
set -eu
work=$(mktemp -d)
finish() {
  rc=$?
  trap - EXIT
  tail -c 1800 "$work/out"
  printf '\n__MARKER__=%s\n' "$rc"
  tail -c 1800 "$work/err" >&2
  rm -rf -- "$work"
  exit "$rc"
}
touch "$work/out" "$work/err"
trap finish EXIT
timeout --signal=TERM --kill-after=10s __TIMEOUT__s bash -seuo pipefail >"$work/out" 2>"$work/err" <<'__DELIMITER__'
__SCRIPT__
__DELIMITER__
'@
  $wrapper = $wrapper.Replace('__MARKER__', $marker).Replace('__TIMEOUT__', "$TimeoutSeconds").
    Replace('__DELIMITER__', $delimiter).Replace('__SCRIPT__', $Script)
  $scriptFile = Join-Path ([IO.Path]::GetTempPath()) "er-$token.sh"
  $failure = $null
  try {
    [IO.File]::WriteAllText($scriptFile, $wrapper.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
    $response = Invoke-ErAzJson -SubscriptionId $SubscriptionId -Arguments @(
      'vm', 'run-command', 'invoke', '--resource-group', $ResourceGroupName,
      '--name', $VmName, '--command-id', 'RunShellScript', '--scripts', "@$scriptFile"
    )
    $raw = ($response.value | ForEach-Object { $_.message }) -join "`n"
    if ($raw -notmatch '(?s)\[stdout\](.*?)\[stderr\](.*)') {
      throw "Unrecognized Run Command output on '$VmName': $raw"
    }
    $stdout = $Matches[1].Trim()
    $stderr = $Matches[2].Trim()
    if ($stdout -notmatch "(?m)^$marker=(\d+)\s*$") {
      throw "Missing remote exit marker on '$VmName' (truncated or interrupted). stdout: $stdout stderr: $stderr"
    }
    $exitCode = [int] $Matches[1]
    $stdout = ($stdout -replace "(?m)^$marker=\d+\s*$", '').Trim()
    if ($exitCode -ne 0) {
      throw "Remote script failed on '$VmName' (exit $exitCode). stdout: $stdout stderr: $stderr"
    }
    if ($stderr) { Write-Warning "${VmName}: $stderr" }
    [pscustomobject]@{ Stdout = $stdout; Stderr = $stderr }
  }
  catch {
    $failure = $_
    throw
  }
  finally {
    try {
      if (Test-Path -LiteralPath $scriptFile) { Remove-Item -LiteralPath $scriptFile -ErrorAction Stop }
    }
    catch {
      if ($failure) { Write-Warning "Temporary script cleanup also failed: $_" }
      else { throw }
    }
  }
}
