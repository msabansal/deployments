[CmdletBinding()]
param(
  [string] $ResourceGroupName = 'sabansal-wireguard-sea-rg',
  [string] $DeploymentName = 'sabansal-wireguard',
  [ValidateSet('Ssh', 'RunCommand')] [string] $Transport = 'Ssh',
  [string] $SshUser = 'azureuser',
  [string] $SshIdentityFile,
  [ValidateRange(1, 32)] [int] $ParallelConnections = 4,
  [ValidateRange(1, 2)] [int] $ServerWorkers = 2,
  [ValidateRange(1, 32)] [int] $StreamsPerConnection = 1,
  [ValidateRange(1, 600)] [int] $DurationSeconds = 30,
  [ValidateRange(1, 60)] [int] $WarmupSeconds = 5,
  [ValidateSet('cubic', 'bbr')] [string] $CongestionControl = 'cubic',
  [ValidateRange(1048576, 1073741824)] [long] $ConnectionWindowBytes = 67108864,
  [ValidateRange(65536, 1073741824)] [long] $StreamWindowBytes = 4194304,
  [ValidateRange(1200, 1472)] [int] $MaxUdpPayloadBytes = 1472,
  [ValidateRange(10, 256)] [int] $InitialCongestionWindowPackets = 32,
  [switch] $DisableGso,
  [switch] $DisableGro,
  [switch] $DisablePacing,
  [switch] $PinProcesses,
  [switch] $Reverse,
  [switch] $SkipInstall,
  [switch] $SetupOnly,
  [switch] $KeepServerRunning,
  [string] $OutputPath
)

$ErrorActionPreference = 'Stop'
$sourceDirectory = Join-Path $PSScriptRoot 'quiche-benchmark'
$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ("quiche-{0}" -f [guid]::NewGuid())
New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
$sshOptions = @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', '-o', 'StrictHostKeyChecking=accept-new')
if ($SshIdentityFile) { $sshOptions += @('-i', $SshIdentityFile) }

function Invoke-QuicheVm {
  param([Parameter(Mandatory)] $Vm, [Parameter(Mandatory)] [string] $Script)
  $scriptText = "set -euo pipefail`n" + ($Script -replace "`r`n", "`n")
  if ($Transport -eq 'Ssh') {
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($scriptText))
    $raw = & ssh @sshOptions "$SshUser@$($Vm.PublicIp)" "printf '%s' '$encoded' | base64 -d | sudo bash" 2>&1
    if ($LASTEXITCODE -ne 0) {
      throw "SSH script failed on $($Vm.Name): $($raw -join "`n")"
    }
    return ($raw -join "`n")
  }
  $file = Join-Path $temporaryDirectory ("command-{0}.sh" -f [guid]::NewGuid())
  [IO.File]::WriteAllText($file, $scriptText, [Text.UTF8Encoding]::new($false))
  $raw = az vm run-command invoke --resource-group $ResourceGroupName --name $Vm.Name `
    --command-id RunShellScript --scripts "@$file" --query 'value[0].message' --output json
  if ($LASTEXITCODE -ne 0) { throw "Azure RunCommand failed on $($Vm.Name)." }
  $message = ($raw -join "`n") | ConvertFrom-Json
  if ($message -notmatch 'QUICHE_COMMAND_OK') {
    throw "Remote command did not complete on $($Vm.Name): $message"
  }
  return [string] $message
}

function Get-QuicheMarker {
  param([string] $Text, [string] $Marker)
  $lines = @($Text -split "`n" | Where-Object { $_.StartsWith("$Marker=") })
  if ($lines.Count -ne 1) { throw "Expected exactly one $Marker result: $Text" }
  return $lines[0].Substring($Marker.Length + 1).Trim()
}

function Get-QuicheCompiledFingerprint {
  $content = [IO.MemoryStream]::new()
  $sha256 = [Security.Cryptography.SHA256]::Create()
  try {
    foreach ($name in @('instrument.py', 'bench.rs', 'Cargo.lock', 'install.sh')) {
      $text = [IO.File]::ReadAllText((Join-Path $sourceDirectory $name)) -replace "`r`n", "`n"
      $bytes = [Text.Encoding]::UTF8.GetBytes($text)
      $content.Write($bytes, 0, $bytes.Length)
    }
    $content.Position = 0
    return [BitConverter]::ToString($sha256.ComputeHash($content)).Replace('-', '').ToLowerInvariant()
  }
  finally { $sha256.Dispose(); $content.Dispose() }
}

function Enable-QuicheServer {
  param(
    [Parameter(Mandatory)] $Vm,
    [Parameter(Mandatory)] [string] $FirewallMarker,
    [Parameter(Mandatory)] [string] $InvocationId
  )
  $retainServer = @'
KEEP_READY=0
rollback_firewall() {
  status=$?
  if [ "$KEEP_READY" != 1 ] && [ -f __FIREWALL_MARKER__.permanent ]; then
    firewall-cmd --permanent --remove-port=4433-4434/udp >&2
    rm -f __FIREWALL_MARKER__.permanent
  fi
  exit "$status"
}
trap rollback_firewall EXIT
if command -v firewall-cmd >/dev/null && systemctl is-active --quiet firewalld; then
  if firewall-cmd --permanent --query-port=4433-4434/udp >/dev/null; then
    :
  else
    status=$?
    if [ "$status" != 1 ]; then exit "$status"; fi
    touch __FIREWALL_MARKER__.permanent
    firewall-cmd --permanent --add-port=4433-4434/udp >/dev/null
  fi
  if firewall-cmd --query-port=4433-4434/udp >/dev/null; then
    :
  else
    status=$?
    if [ "$status" != 1 ]; then exit "$status"; fi
    touch __FIREWALL_MARKER__.runtime
    firewall-cmd --add-port=4433-4434/udp >/dev/null
  fi
fi
if [ -f /etc/systemd/system/quiche-benchmark-cpu.service ]; then
  systemctl stop quiche-benchmark-cpu
fi
systemctl is-active --quiet quiche-benchmark
if [ "$(systemctl show quiche-benchmark -p InvocationID --value)" != __INVOCATION_ID__ ]; then
  echo "quiche server restarted before persistence confirmation" >&2
  exit 1
fi
systemctl enable --now quiche-benchmark
systemctl is-enabled --quiet quiche-benchmark
systemctl is-active --quiet quiche-benchmark
if [ "$(systemctl show quiche-benchmark -p InvocationID --value)" != __INVOCATION_ID__ ]; then
  echo "quiche server restarted during persistence confirmation" >&2
  exit 1
fi
KEEP_READY=1
echo QUICHE_SERVER_RETAINED=1
echo QUICHE_COMMAND_OK
'@ -replace '__FIREWALL_MARKER__', $FirewallMarker -replace '__INVOCATION_ID__', $InvocationId
  $retainText = Invoke-QuicheVm -Vm $Vm -Script $retainServer
  if ((Get-QuicheMarker $retainText QUICHE_SERVER_RETAINED) -ne '1') {
    throw 'Could not verify persistent quiche server configuration.'
  }
}

function Save-QuicheResult {
  param([Parameter(Mandatory)] $Result)
  if ($OutputPath) {
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath), ($Result | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
  }
}

$server = $null
$serverStarted = $false
$keepCommitted = $false
$retainRequested = $KeepServerRunning -or $SetupOnly
$firewallMarker = "/opt/quiche-benchmark/firewall-$([guid]::NewGuid().ToString('N'))"
try {
  $expectedFingerprint = Get-QuicheCompiledFingerprint
  $runtimeHashes = [ordered]@{}
  foreach ($name in @('server.py', 'measure.py')) {
    $text = [IO.File]::ReadAllText((Join-Path $sourceDirectory $name)) -replace "`r`n", "`n"
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
      $runtimeHashes[$name] = [BitConverter]::ToString(
        $sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($text))).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha256.Dispose() }
  }
  $runtimeHashesJson = $runtimeHashes | ConvertTo-Json -Compress
  $raw = az deployment group show --resource-group $ResourceGroupName --name $DeploymentName `
    --query properties.outputs --output json
  if ($LASTEXITCODE -ne 0) { throw "Cannot resolve deployment '$DeploymentName'." }
  $outputs = ($raw -join "`n") | ConvertFrom-Json
  foreach ($name in @('serverVmName', 'clientVmName', 'serverPrivateIp', 'clientPrivateIp', 'serverPublicIp', 'clientPublicIp')) {
    if (-not $outputs.$name.value) { throw "Missing deployment output '$name'." }
  }
  $server = [pscustomobject]@{
    Name = $outputs.serverVmName.value
    PrivateIp = $outputs.serverPrivateIp.value
    PublicIp = $outputs.serverPublicIp.value
  }
  $client = [pscustomobject]@{
    Name = $outputs.clientVmName.value
    PrivateIp = $outputs.clientPrivateIp.value
    PublicIp = $outputs.clientPublicIp.value
  }
  if ($Reverse) { $swap = $server; $server = $client; $client = $swap }

  if (-not $SkipInstall) {
    $staging = Join-Path $temporaryDirectory 'upload'
    New-Item -ItemType Directory -Path $staging | Out-Null
    foreach ($name in @('Cargo.lock', 'bench.rs', 'instrument.py', 'install.sh', 'measure.py', 'server.py')) {
      $text = [IO.File]::ReadAllText((Join-Path $sourceDirectory $name)) -replace "`r`n", "`n"
      [IO.File]::WriteAllText((Join-Path $staging $name), $text, [Text.UTF8Encoding]::new($false))
    }
    $archive = Join-Path $temporaryDirectory 'harness.tar.gz'
    tar -czf $archive -C $staging .
    if ($LASTEXITCODE -ne 0) { throw 'Could not create normalized harness archive.' }
    foreach ($vm in @($server, $client)) {
      if ($Transport -eq 'Ssh') {
        scp @sshOptions -q $archive "${SshUser}@$($vm.PublicIp):/tmp/quiche-benchmark-harness.tar.gz"
        if ($LASTEXITCODE -ne 0) { throw "Upload failed on $($vm.Name)." }
        $upload = ''
      }
      else {
        $base64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($archive))
        $upload = "printf '%s' '$base64' | base64 -d >/tmp/quiche-benchmark-harness.tar.gz`n"
      }
      $install = $upload + @'
install -d /opt/quiche-benchmark-harness
tar -xzf /tmp/quiche-benchmark-harness.tar.gz -C /opt/quiche-benchmark-harness
if ! bash /opt/quiche-benchmark-harness/install.sh >/opt/quiche-benchmark-harness/build.log 2>&1; then
  tail -n 50 /opt/quiche-benchmark-harness/build.log >&2
  exit 1
fi
rm -f /tmp/quiche-benchmark-harness.tar.gz
echo QUICHE_COMMAND_OK
'@
      Invoke-QuicheVm -Vm $vm -Script $install | Out-Null
    }
  }

  $validateBuild = @'
python3 - <<'PY'
import hashlib, json, os, pathlib, subprocess
prefix = pathlib.Path("/opt/quiche-benchmark")
data = json.loads((prefix / "source.json").read_text())
expected = {
    "quiche_version": "0.30.0",
    "source_commit": "be47c5011215b9f13bad06bd7627d3ae49888a19",
    "instrumentation_sha256": "__FINGERPRINT__",
}
for name, value in expected.items():
    if data.get(name) != value:
        raise RuntimeError(f"Installed {name} mismatch: expected {value}, got {data.get(name)}. Rerun without -SkipInstall.")
for name in ("quiche-server", "quiche-client"):
    binary = prefix / "bin" / name
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise RuntimeError(f"Missing executable {binary}. Rerun without -SkipInstall.")
    probe = subprocess.run([str(binary), "--help"], capture_output=True, text=True, check=True)
    if f"Usage:\n  {name}" not in probe.stdout:
        raise RuntimeError(f"Unexpected executable identity: {binary}")
harness = pathlib.Path("/opt/quiche-benchmark-harness")
for name, expected_hash in json.loads('__RUNTIME_HASHES__').items():
    path = harness / name
    if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected_hash:
        raise RuntimeError(f"Runtime harness {name} does not match current local source. Rerun without -SkipInstall; matching Rust binaries will be reused.")
for name, subcommand in (("server.py", []), ("measure.py", ["client"])):
    probe = subprocess.run(["python3", str(harness / name), *subcommand, "--help"],
                           capture_output=True, text=True)
    if probe.returncode or "--pin-processes" not in probe.stdout:
        raise RuntimeError(f"Runtime harness {name} is missing or outdated: {probe.stderr}. Rerun without -SkipInstall; matching Rust binaries will be reused.")
busy_polling = {}
for name in ("busy_poll", "busy_read"):
    text = pathlib.Path(f"/proc/sys/net/core/{name}").read_text().strip()
    if not text.isascii() or not text.isdecimal():
        raise RuntimeError(f"Invalid net.core.{name} value: {text!r}")
    busy_polling[name] = int(text)
print("QUICHE_BUSY_POLLING=" + json.dumps(busy_polling))
PY
echo "QUICHE_BUILD=$(cat /opt/quiche-benchmark/source.json)"
echo QUICHE_COMMAND_OK
'@ -replace '__FINGERPRINT__', $expectedFingerprint -replace '__RUNTIME_HASHES__', $runtimeHashesJson
  $builds = @{}
  $busyPolling = @{}
  foreach ($vm in @($server, $client)) {
    $buildText = Invoke-QuicheVm -Vm $vm -Script $validateBuild
    $builds[$vm.Name] = (Get-QuicheMarker $buildText QUICHE_BUILD) | ConvertFrom-Json
    $busyPolling[$vm.Name] = (Get-QuicheMarker $buildText QUICHE_BUSY_POLLING) | ConvertFrom-Json
  }

  $serverArguments = "--http-version HTTP/3 --cert /opt/quiche-benchmark/cert.pem --key /opt/quiche-benchmark/key.pem --cc-algorithm $CongestionControl --max-data $ConnectionWindowBytes --max-window $ConnectionWindowBytes --max-stream-data $StreamWindowBytes --max-stream-window $StreamWindowBytes --initial-rtt 1 --initial-cwnd-packets $InitialCongestionWindowPackets --idle-timeout 600000"
  if ($DisableGso) { $serverArguments += ' --disable-gso' }
  if ($DisablePacing) { $serverArguments += ' --disable-pacing' }
  $pinArguments = if ($PinProcesses) { '--pin-processes' } else { '' }
  $startServer = @'
test -x /opt/quiche-benchmark/bin/quiche-server
test -s /opt/quiche-benchmark/source.json
if [ ! -s /opt/quiche-benchmark/cert.pem ] ||
   ! openssl x509 -checkend 3600 -noout -in /opt/quiche-benchmark/cert.pem >/dev/null; then
  umask 077
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -sha256 -nodes \
    -keyout /opt/quiche-benchmark/key.pem -out /opt/quiche-benchmark/cert.pem \
    -days 7 -subj '/CN=quiche-benchmark.internal' \
    -addext 'subjectAltName=DNS:quiche-benchmark.internal' \
    -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,digitalSignature,keyCertSign' \
    -addext 'extendedKeyUsage=serverAuth' >/dev/null 2>&1
fi
if command -v firewall-cmd >/dev/null && systemctl is-active --quiet firewalld; then
  if firewall-cmd --query-port=4433-4434/udp >/dev/null; then
    :
  else
    status=$?
    if [ "$status" != 1 ]; then exit "$status"; fi
    touch __FIREWALL_MARKER__.runtime
    firewall-cmd --add-port=4433-4434/udp >/dev/null
  fi
fi
cat >/etc/systemd/system/quiche-benchmark.service <<'EOF'
[Unit]
Description=Pinned cloudflare quiche encrypted throughput benchmark
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
Environment=QUICHE_BENCH_SERVER=1
Environment=QUICHE_BENCH_MAX_UDP=__MAX_UDP__
Environment=RUST_LOG=error
ExecStart=/usr/bin/python3 /opt/quiche-benchmark-harness/server.py --workers __WORKERS__ --listen-ip __LISTEN_IP__ __PIN_PROCESSES__ -- __SERVER_ARGS__
Restart=on-failure
RestartSec=2
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl restart quiche-benchmark
for attempt in $(seq 1 20); do
  if systemctl is-active --quiet quiche-benchmark; then
    MAINPID=$(systemctl show quiche-benchmark -p MainPID --value)
    INVOCATION_ID=$(systemctl show quiche-benchmark -p InvocationID --value)
    if SETTINGS=$(journalctl _SYSTEMD_UNIT=quiche-benchmark.service "_PID=$MAINPID" \
                  "_SYSTEMD_INVOCATION_ID=$INVOCATION_ID" --no-pager -o cat |
                  grep '^QUICHE_SERVER_SETTINGS=' | tail -n 1); then
      echo "$SETTINGS"
      echo "QUICHE_SERVER_INVOCATION_ID=$INVOCATION_ID"
      echo "QUICHE_CERT=$(base64 -w0 /opt/quiche-benchmark/cert.pem)"
      echo QUICHE_COMMAND_OK
      exit 0
    fi
  fi
  sleep 1
done
journalctl -u quiche-benchmark -n 30 --no-pager >&2
exit 1
'@ -replace '__MAX_UDP__', $MaxUdpPayloadBytes -replace '__SERVER_ARGS__', $serverArguments -replace '__WORKERS__', $ServerWorkers -replace '__LISTEN_IP__', $server.PrivateIp -replace '__FIREWALL_MARKER__', $firewallMarker -replace '__PIN_PROCESSES__', $pinArguments
  # Set before starting so even partial startup failures receive targeted cleanup.
  $serverStarted = $true
  $startText = Invoke-QuicheVm -Vm $server -Script $startServer
  $cert = Get-QuicheMarker -Text $startText -Marker QUICHE_CERT
  $serverInvocationId = Get-QuicheMarker $startText QUICHE_SERVER_INVOCATION_ID
  if ($serverInvocationId -notmatch '^[0-9a-f]{32}$') { throw 'Invalid systemd server invocation ID.' }
  $prepareClient = @'
test -x /opt/quiche-benchmark/bin/quiche-client
printf '%s' '__CERT__' | base64 -d >/opt/quiche-benchmark/server-cert.pem
openssl verify -CAfile /opt/quiche-benchmark/server-cert.pem \
  -verify_hostname quiche-benchmark.internal -purpose sslserver \
  /opt/quiche-benchmark/server-cert.pem >/dev/null
ROUTE=$(ip route get __TARGET__)
if echo "$ROUTE" | grep -q 'dev wg0'; then
  echo "QUIC underlay route unexpectedly uses WireGuard: $ROUTE" >&2
  exit 1
fi
echo "QUICHE_CERT_SHA256=$(openssl x509 -in /opt/quiche-benchmark/server-cert.pem -noout -fingerprint -sha256 | cut -d= -f2)"
echo "QUICHE_CERT_NOT_AFTER=$(openssl x509 -in /opt/quiche-benchmark/server-cert.pem -noout -enddate | cut -d= -f2)"
echo QUICHE_COMMAND_OK
'@ -replace '__CERT__', $cert -replace '__TARGET__', $server.PrivateIp
  $prepareText = Invoke-QuicheVm -Vm $client -Script $prepareClient
  $certFingerprint = Get-QuicheMarker $prepareText QUICHE_CERT_SHA256
  $certNotAfter = Get-QuicheMarker $prepareText QUICHE_CERT_NOT_AFTER
  $serverRuntime = (Get-QuicheMarker $startText QUICHE_SERVER_SETTINGS) | ConvertFrom-Json
  $serverRuntime | Add-Member invocation_id $serverInvocationId
  $settings = [ordered]@{
    congestion_control = $CongestionControl
    connection_window_bytes = $ConnectionWindowBytes
    stream_window_bytes = $StreamWindowBytes
    max_udp_payload_bytes = $MaxUdpPayloadBytes
    initial_cwnd_packets = $InitialCongestionWindowPackets
    gso_requested = -not $DisableGso
    gro_requested = -not $DisableGro
    pacing_requested = -not $DisablePacing
    pin_processes_requested = [bool]$PinProcesses
    kernel_busy_polling = [ordered]@{
      server = $busyPolling[$server.Name]
      client = $busyPolling[$client.Name]
    }
    server_process_affinities = @($serverRuntime.workers | ForEach-Object {
      [ordered]@{ process_index = $_.index; process_id = $_.process_id; cpu_ids = @($_.cpu_affinity) }
    })
    reverse = [bool]$Reverse
    setup_only = [bool]$SetupOnly
    keep_server_running_requested = [bool]$retainRequested
    underlay_mtu = 1500
  }
  if ($SetupOnly) {
    $result = [pscustomobject][ordered]@{
      mode = 'setup'
      status = 'ready'
      measurement_performed = $false
      server_running = $true
      server_enabled_for_boot = $true
      service_unit = '/etc/systemd/system/quiche-benchmark.service'
      server_vm = $server.Name
      client_vm = $client.Name
      target_ip = $server.PrivateIp
      server_workers = $ServerWorkers
      build = $builds[$client.Name]
      server_build = $builds[$server.Name]
      server_runtime = $serverRuntime
      certificate = [ordered]@{
        dns_name = 'quiche-benchmark.internal'
        trust_anchor_path = '/opt/quiche-benchmark/server-cert.pem'
        sha256_fingerprint = $certFingerprint
        not_after = $certNotAfter
        validated = $true
        handshake_tested = $false
      }
      settings = $settings
    }
    Enable-QuicheServer -Vm $server -FirewallMarker $firewallMarker -InvocationId $serverInvocationId
    Save-QuicheResult -Result $result
    $keepCommitted = $true
    Write-Host "quiche HTTP/3 setup ready: $($server.Name); $ServerWorkers workers; server enabled for boot; no measurement performed."
    $result
    return
  }

  $lead = if ($Transport -eq 'Ssh') { $WarmupSeconds + 5 } else { $WarmupSeconds + 120 }
  $schedule = "echo `"QUICHE_START=`$(python3 -c 'import time; print(time.time()+$lead)')`"`necho QUICHE_COMMAND_OK"
  $start = Get-QuicheMarker -Text (Invoke-QuicheVm -Vm $client -Script $schedule) -Marker QUICHE_START
  $cpuStart = @'
rm -f /opt/quiche-benchmark/server-cpu.json
cat >/etc/systemd/system/quiche-benchmark-cpu.service <<'EOF'
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /opt/quiche-benchmark-harness/measure.py cpu --start __START__ --duration __DURATION__ --output /opt/quiche-benchmark/server-cpu.json
EOF
systemctl daemon-reload
systemctl start --no-block quiche-benchmark-cpu
echo QUICHE_COMMAND_OK
'@ -replace '__START__', $start -replace '__DURATION__', $DurationSeconds
  Invoke-QuicheVm -Vm $server -Script $cpuStart | Out-Null
  $measure = "python3 /opt/quiche-benchmark-harness/measure.py client --target $($server.PrivateIp) --cert /opt/quiche-benchmark/server-cert.pem --connections $ParallelConnections --server-workers $ServerWorkers --streams $StreamsPerConnection --duration $DurationSeconds --warmup $WarmupSeconds --start $start --cc $CongestionControl --window $ConnectionWindowBytes --stream-window $StreamWindowBytes --max-udp $MaxUdpPayloadBytes --initial-cwnd $InitialCongestionWindowPackets --output /opt/quiche-benchmark/client-result.json`necho QUICHE_COMMAND_OK"
  if ($DisableGro) { $measure = $measure -replace '--output ', '--disable-gro --output ' }
  if ($PinProcesses) { $measure = $measure -replace '--output ', '--pin-processes --output ' }
  $clientText = Invoke-QuicheVm -Vm $client -Script $measure
  $compressed = [IO.MemoryStream]::new([Convert]::FromBase64String((Get-QuicheMarker -Text $clientText -Marker QUICHE_CLIENT_RESULT_B64)))
  $gzip = [IO.Compression.GZipStream]::new($compressed, [IO.Compression.CompressionMode]::Decompress)
  $reader = [IO.StreamReader]::new($gzip)
  try { $result = $reader.ReadToEnd() | ConvertFrom-Json }
  finally { $reader.Dispose(); $gzip.Dispose(); $compressed.Dispose() }
  $serverMetrics = @'
test -s /opt/quiche-benchmark/server-cpu.json
echo "QUICHE_SERVER_CPU=$(cat /opt/quiche-benchmark/server-cpu.json)"
echo "QUICHE_SERVER_BUILD=$(cat /opt/quiche-benchmark/source.json)"
MAINPID=$(systemctl show quiche-benchmark -p MainPID --value)
systemctl is-active --quiet quiche-benchmark
if [ "$(systemctl show quiche-benchmark -p InvocationID --value)" != __INVOCATION_ID__ ]; then
  echo "quiche server restarted during measurement" >&2
  exit 1
fi
journalctl _SYSTEMD_UNIT=quiche-benchmark.service "_PID=$MAINPID" \
  "_SYSTEMD_INVOCATION_ID=__INVOCATION_ID__" --no-pager -o cat |
  grep '^QUICHE_SERVER_SETTINGS=' | tail -n 1
GSO=$(journalctl _SYSTEMD_UNIT=quiche-benchmark.service "_PID=$MAINPID" \
  "_SYSTEMD_INVOCATION_ID=__INVOCATION_ID__" --no-pager -o cat |
  grep '^QUICHE_GSO_SENDS=' | tail -n 1)
if [ -z "$GSO" ]; then echo "Missing server GSO telemetry" >&2; exit 1; fi
if [ "$(systemctl show quiche-benchmark -p InvocationID --value)" != __INVOCATION_ID__ ]; then
  echo "quiche server restarted while reading measurement telemetry" >&2
  exit 1
fi
echo "$GSO"
echo QUICHE_COMMAND_OK
'@ -replace '__INVOCATION_ID__', $serverInvocationId
  $serverText = Invoke-QuicheVm -Vm $server -Script $serverMetrics
  $result | Add-Member server_cpu ((Get-QuicheMarker $serverText QUICHE_SERVER_CPU) | ConvertFrom-Json)
  $result | Add-Member server_build ((Get-QuicheMarker $serverText QUICHE_SERVER_BUILD) | ConvertFrom-Json)
  $result | Add-Member server_runtime ((Get-QuicheMarker $serverText QUICHE_SERVER_SETTINGS) | ConvertFrom-Json)
  $result.server_runtime | Add-Member invocation_id $serverInvocationId
  $result.server_runtime | Add-Member gso_sendmsg_calls ([long](Get-QuicheMarker $serverText QUICHE_GSO_SENDS))
  $settings.client_process_affinities = @($result.receiver_results | ForEach-Object {
    [ordered]@{ process_index = $_.process_index; process_id = $_.process_id; cpu_ids = @($_.cpu_affinity) }
  })
  $result | Add-Member settings $settings
  $result | Add-Member server_vm $server.Name
  $result | Add-Member client_vm $client.Name
  $result | Add-Member target_ip $server.PrivateIp
  if ($result.build.source_commit -ne 'be47c5011215b9f13bad06bd7627d3ae49888a19' -or
      $result.server_build.source_commit -ne $result.build.source_commit -or
      $result.build.quiche_version -ne '0.30.0' -or
      $result.server_build.quiche_version -ne '0.30.0' -or
      $result.build.instrumentation_sha256 -ne $expectedFingerprint -or
      $result.server_build.instrumentation_sha256 -ne $expectedFingerprint) {
    throw 'Client/server source version or instrumentation mismatch.'
  }
  if ($result.bytes_received -le 0 -or $result.duration_seconds -ne $DurationSeconds) {
    throw 'Invalid receiver application-byte measurement.'
  }
  Save-QuicheResult -Result $result
  if ($retainRequested) {
    Enable-QuicheServer -Vm $server -FirewallMarker $firewallMarker -InvocationId $serverInvocationId
    $keepCommitted = $true
  }
  Write-Host ("quiche HTTP/3 receiver goodput: {0:N3} Gbit/s; {1} connections; client CPU {2:N1}%, server CPU {3:N1}%" -f ($result.bits_per_second / 1e9), $ParallelConnections, $result.client_cpu.vm_cpu_percent, $result.server_cpu.vm_cpu_percent)
  $result
}
finally {
  if ($serverStarted) {
    try {
      $cleanup = @'
STATUS=0
if [ -f /etc/systemd/system/quiche-benchmark-cpu.service ]; then
  systemctl stop quiche-benchmark-cpu || STATUS=$?
fi
if [ __KEEP__ != 1 ]; then
  if [ -f /etc/systemd/system/quiche-benchmark.service ]; then
    systemctl stop quiche-benchmark || STATUS=$?
    systemctl disable quiche-benchmark || STATUS=$?
  fi
  if [ -f __FIREWALL_MARKER__.runtime ]; then
    firewall-cmd --remove-port=4433-4434/udp >/dev/null || STATUS=$?
  fi
  if [ -f __FIREWALL_MARKER__.permanent ]; then
    firewall-cmd --permanent --remove-port=4433-4434/udp >/dev/null || STATUS=$?
  fi
fi
rm -f __FIREWALL_MARKER__.runtime __FIREWALL_MARKER__.permanent
if [ "$STATUS" != 0 ]; then exit "$STATUS"; fi
echo QUICHE_COMMAND_OK
'@ -replace '__KEEP__', [int]$keepCommitted -replace '__FIREWALL_MARKER__', $firewallMarker
      Invoke-QuicheVm -Vm $server -Script $cleanup | Out-Null
    }
    catch { Write-Warning "Dedicated quiche service cleanup failed: $($_.Exception.Message)" }
  }
  Get-ChildItem -LiteralPath $temporaryDirectory -File | Remove-Item
  $uploadDirectory = Join-Path $temporaryDirectory 'upload'
  if (Test-Path -LiteralPath $uploadDirectory) {
    Get-ChildItem -LiteralPath $uploadDirectory -File | Remove-Item
    Remove-Item -LiteralPath $uploadDirectory
  }
  Remove-Item -LiteralPath $temporaryDirectory
}
