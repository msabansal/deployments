[CmdletBinding()]
param(
  [string] $ResourceGroupName = 'sabansal-ilb-routing-two-infra-rg',
  [string] $DeploymentName = 'sabansal-ilb-routing-two-infra',
  [string] $Location = 'westus3',
  [string] $SshPublicKeyPath = '~\.ssh\id_ed25519.pub',
  [string] $SshPrivateKeyPath = '~\.ssh\id_ed25519',
  [string] $SwiftBinaryPath = 'Q:\az\Networking-Hybrid-SurgeGuard\AKS-Multitenancy\SwiftCli\bin\Release\net10.0\linux-x64\publish\swiftcmd',
  [string] $NrpSubnetDelegatorProject = 'Q:\az\Networking-Hybrid-SurgeGuard\AKS-Multitenancy\NrpSubnetDelegatorCli\NrpSubnetDelegatorCli.csproj',
  [string] $KeyVaultName = 'testGWMSS',
  [string] $CertificateName = 'prodnextappCert',
  [string] $AppId = 'f6f9bf50-8786-4efb-a1c6-776f770b4b65',
  [string] $TenantId = '72f988bf-86f1-41af-91ab-2d7cd011db47',
  [string] $LinkedResourceType = 'Microsoft.Network/applicationGateways',
  [string] $VmSize = 'Standard_D2als_v7',
  [switch] $SkipTopologyDeployment,
  [switch] $SkipThroughputTest,
  [switch] $CleanupSwift,
  [ValidateSet('router1', 'router2')]
  [string] $BackendRouter = 'router2',
  [switch] $ConnectivityOnly,
  [ValidateRange(1, 30)]
  [int] $ConnectivityTimeoutSeconds = 5,
  [ValidateRange(30, 900)]
  [int] $SwiftSetupTimeoutSeconds = 120,
  [ValidateRange(1, 100000)]
  [int] $UdpTargetMbps = 5000,
  [ValidateRange(5, 600)]
  [int] $DurationSeconds = 30
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\swift-ssh.ps1"

function ConvertTo-BashArgument {
  param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Value)
  return "'" + $Value.Replace("'", "'\''") + "'"
}

function Get-RouterCommand {
  param(
    [Parameter(Mandatory)] [object] $Router,
    [string] $AuthToken = '',
    [switch] $Cleanup
  )

  $settings = @{
    '__ACTION__' = $(if ($Cleanup) { 'cleanup' } else { 'create' })
    '__NAMESPACE__' = $Router.Namespace
    '__SWIFT_IP__' = $Router.Ip
    '__VLAN__' = [string]$Router.Vlan
    '__VNET_GUID__' = [string]$outputs.customerVnetGuid.value
    '__SUBNET__' = [string]$outputs.routingSubnetName.value
    '__AUTH_TOKEN__' = $AuthToken
  }
  $command = Get-Content -LiteralPath "$PSScriptRoot\configure-swift-router.sh" -Raw
  foreach ($key in $settings.Keys) {
    $command = $command.Replace($key, (ConvertTo-BashArgument -Value ([string]$settings[$key])))
  }
  return $command
}

function Get-RouterInventory {
  param([Parameter(Mandatory)] [object] $Router)

  $command = @'
set -euo pipefail
python3 - <<'PY'
import json, pathlib, subprocess
states = []
for path in pathlib.Path("/var/lib/swift-ilb").glob("*.json"):
    state = json.loads(path.read_text())
    if path.name != state["namespace"] + ".json":
        raise RuntimeError("Managed SWIFT state filename mismatch")
    states.append({key: state[key] for key in ("namespace", "ip", "vlan", "ncId", "vnetGuid", "subnet")})
namespaces = json.loads(subprocess.check_output(["ip", "-j", "netns", "list"], text=True, timeout=10))
root_links = json.loads(subprocess.check_output(["ip", "-j", "-4", "addr", "show"], text=True, timeout=10))
customer_ips = [{"namespace": "", "ip": addr["local"]}
                for link in root_links for addr in link.get("addr_info", [])
                if addr["local"].startswith("10.80.")]
for namespace in namespaces:
    links = json.loads(subprocess.check_output(
        ["ip", "-j", "-n", namespace["name"], "-4", "addr", "show"], text=True, timeout=10))
    customer_ips += [{"namespace": namespace["name"], "ip": addr["local"]}
                     for link in links for addr in link.get("addr_info", [])
                     if addr["local"].startswith("10.80.")]
nc_ids = None
if pathlib.Path("/usr/local/bin/swiftcmd").is_file():
    raw = subprocess.check_output(["/usr/local/bin/swiftcmd", "get-all-ncs"], text=True, timeout=15)
    report = json.loads(raw[raw.index("{"):])
    entries = report.get("networkContainers", report.get("NetworkContainers"))
    if entries is None and ("networkContainers" in report or "NetworkContainers" in report):
        entries = []
    if not isinstance(entries, list):
        raise RuntimeError("Unrecognized SWIFT NC inventory")
    nc_ids = [entry.get("networkContainerId") or entry["NetworkContainerId"] for entry in entries]
print("__SWIFT_INVENTORY__=" + json.dumps({
    "states": states, "namespaces": [entry["name"] for entry in namespaces],
    "customerIps": customer_ips, "ncIds": nc_ids
}, separators=(",", ":")))
PY
'@
  $captured = [Collections.Generic.List[string]]::new()
  Invoke-ResilientSshCommand -HostAddress $Router.HostAddress -Command $command `
    -OperationName "$($Router.Name) SWIFT inventory" -TimeoutSeconds 30 -CapturedOutput $captured | Out-Null
  $reports = @($captured | Where-Object { $_.StartsWith('__SWIFT_INVENTORY__=') })
  if ($reports.Count -ne 1) { throw "No unique SWIFT inventory was returned by $($Router.Name)." }
  return ($reports[0].Substring('__SWIFT_INVENTORY__='.Length) | ConvertFrom-Json)
}

function Assert-SingleBackendPlacement {
  param([Parameter(Mandatory)] [object[]] $Routers, [Parameter(Mandatory)] [object] $Selected)

  foreach ($router in $Routers) {
    $inventory = Get-RouterInventory -Router $router
    $states = @($inventory.states)
    $expectedCount = 0
    if ($router.Name -eq $Selected.Name -and $states.Count -eq 1) {
      $state = $states[0]
      if ($state.namespace -ne $Selected.Namespace -or $state.ip -ne '10.80.0.5' -or
          $state.vlan -ne $Selected.Vlan -or $state.vnetGuid -ne $outputs.customerVnetGuid.value -or
          $state.subnet -ne $outputs.routingSubnetName.value) {
        throw "Conflicting managed placement on $($router.Name). Run -CleanupSwift or the migration tool before selecting $BackendRouter."
      }
      $expectedCount = 1
    }
    if ($states.Count -ne $expectedCount -or $null -eq $inventory.ncIds -or
        @($inventory.ncIds).Count -ne $expectedCount -or
        ($expectedCount -eq 1 -and $inventory.ncIds[0] -ne $states[0].ncId) -or
        @($inventory.customerIps).Count -gt $expectedCount -or
        @($inventory.customerIps | Where-Object {
          $_.namespace -ne $Selected.Namespace -or $_.ip -ne '10.80.0.5' -or $router.Name -ne $Selected.Name
        }).Count -gt 0 -or
        @($inventory.namespaces | Where-Object {
          $_ -in @('swift-ilb-router1', 'swift-ilb-router2', 'swift-ilb-backend2') -and
          ($router.Name -ne $Selected.Name -or $_ -ne $Selected.Namespace -or $expectedCount -eq 0)
        }).Count -gt 0) {
      throw "Conflicting or untracked SWIFT attachments on $($router.Name); refusing to create a duplicate backend. Explicitly clean up managed attachments first."
    }
  }
}

$privateKeyPath = Resolve-RequiredFile $SshPrivateKeyPath
if (-not $CleanupSwift) {
  $swiftBinary = Resolve-RequiredFile $SwiftBinaryPath
  $delegatorProject = Resolve-RequiredFile $NrpSubnetDelegatorProject
  if (-not $SkipTopologyDeployment) {
    $keyPath = Resolve-RequiredFile $SshPublicKeyPath
    $publicKey = (Get-Content -LiteralPath $keyPath -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($publicKey)) { throw 'The SSH public key is empty.' }

    az group create --name $ResourceGroupName --location $Location --output none
    Assert-LastExitCode 'Resource group creation'

    Write-Log -Level STEP -Message 'Deploying isolated infra and customer VNets. Existing routers on customer NICs must be recreated before this deployment.'
    az deployment group create `
      --resource-group $ResourceGroupName `
      --name $DeploymentName `
      --template-file "$PSScriptRoot\main.bicep" `
      --parameters "$PSScriptRoot\main.bicepparam" `
      --parameters "location=$Location" "adminPublicKey=$publicKey" "vmSize=$VmSize" "backendRouter=$BackendRouter" `
      --output none
    Assert-LastExitCode 'Azure topology deployment'
  }
}

$outputs = az deployment group show `
  --resource-group $ResourceGroupName --name $DeploymentName `
  --query properties.outputs -o json | ConvertFrom-Json
Assert-LastExitCode 'Reading topology outputs'

foreach ($name in @('infraVnetId', 'customerVnetId', 'customerVnetGuid', 'routingSubnetId', 'routingSubnetName',
    'routingBackendIp', 'router1Name', 'router2Name', 'router1PublicIp', 'router2PublicIp')) {
  if ($null -eq $outputs.$name.value -or [string]::IsNullOrWhiteSpace([string]$outputs.$name.value)) {
    throw "Deployment is missing output '$name'; deploy the corrected SWIFT topology first."
  }
}
if ($outputs.infraVnetId.value -eq $outputs.customerVnetId.value) {
  throw 'Infrastructure and customer VNets must be different.'
}
$routers = @(
  [pscustomobject]@{
    Name = $outputs.router1Name.value
    HostAddress = $outputs.router1PublicIp.value
    Namespace = 'swift-ilb-router1'
    Ip = '10.80.0.5'
    Vlan = 1
  },
  [pscustomobject]@{
    Name = $outputs.router2Name.value
    HostAddress = $outputs.router2PublicIp.value
    Namespace = 'swift-ilb-backend2'
    Ip = '10.80.0.5'
    Vlan = 2
  }
)
if ($outputs.routingBackendIp.value -ne '10.80.0.5') { throw 'Only SWIFT backend 10.80.0.5 is supported.' }
$selected = $routers[$(if ($BackendRouter -eq 'router1') { 0 } else { 1 })]

if ($CleanupSwift) {
  $failures = @()
  foreach ($router in $routers) {
    try {
      $inventory = Get-RouterInventory -Router $router
      $managed = @($router)
      if ($router.Name -eq $routers[1].Name) {
        $managed += [pscustomobject]@{
          Name = $router.Name; HostAddress = $router.HostAddress
          Namespace = 'swift-ilb-router2'; Ip = '10.80.0.6'; Vlan = 1
        }
      }
      foreach ($attachment in $managed) {
        $states = @($inventory.states | Where-Object { $_.namespace -eq $attachment.Namespace })
        if ($states.Count -eq 0) {
          if ($inventory.namespaces -contains $attachment.Namespace) {
            throw "Namespace $($attachment.Namespace) has no managed state; refusing untracked cleanup."
          }
          continue
        }
        if ($states.Count -ne 1 -or $states[0].ip -ne $attachment.Ip -or $states[0].vlan -ne $attachment.Vlan -or
            $states[0].vnetGuid -ne $outputs.customerVnetGuid.value -or $states[0].subnet -ne $outputs.routingSubnetName.value) {
          throw "Refusing mismatched managed attachment $($attachment.Namespace)."
        }
        Invoke-ResilientSshCommand -HostAddress $router.HostAddress `
          -Command (Get-RouterCommand -Router $attachment -Cleanup) `
          -OperationName "$($router.Name) $($attachment.Namespace) cleanup" -TimeoutSeconds 30 | Out-Null
      }
    }
    catch { $failures += "$($router.Name): $($_.Exception.Message)" }
  }
  if ($failures.Count) { throw ($failures -join "`n") }
  Write-Log -Level SUCCESS -Message 'Managed backend and any legacy .6 attachment were cleaned up. Unmanaged attachments, Azure resources, and subnet delegation were retained.'
  return
}

foreach ($router in $routers) {
  Write-Log -Level STEP -Message "Installing swiftcmd on $($router.Name) for preflight inventory."
  $copied = $false
  $remoteBinary = "/tmp/swiftcmd-$([guid]::NewGuid().ToString('N'))"
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    scp -q -i $privateKeyPath -o BatchMode=yes -o StrictHostKeyChecking=accept-new `
      -o ConnectTimeout=5 $swiftBinary "azureuser@$($router.HostAddress):$remoteBinary"
    if ($LASTEXITCODE -eq 0) { $copied = $true; break }
    if ($attempt -lt 3) { Start-Sleep -Seconds 3 }
  }
  if (-not $copied) { throw "Could not copy swiftcmd to $($router.Name)." }
  ssh -i $privateKeyPath -o BatchMode=yes -o StrictHostKeyChecking=accept-new `
    -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 "azureuser@$($router.HostAddress)" `
    "sudo install -m 0755 '$remoteBinary' /usr/local/bin/swiftcmd && rm -f '$remoteBinary'"
  Assert-LastExitCode "Installing swiftcmd on $($router.Name)"
}
Assert-SingleBackendPlacement -Routers $routers -Selected $selected

Write-Log -Level STEP -Message 'Delegating the customer routing subnet and assigning ownership to the infrastructure VNet.'
$delegatorArgs = @(
  'run', '--project', $delegatorProject, '--',
  '--key-vault-name', $KeyVaultName, '--certificate-name', $CertificateName,
  '--app-id', $AppId, '--tenant-id', $TenantId,
  '--subnet-resource-id', [string]$outputs.routingSubnetId.value,
  '--vnet-resource-id', [string]$outputs.infraVnetId.value,
  '--linked-resource-type', $LinkedResourceType
)
$delegationResult = $null
& dotnet @delegatorArgs 2>&1 | ForEach-Object {
  $line = [string]$_
  if ($line -match '^DelegationResult: (.+)$') {
    $result = $Matches[1] | ConvertFrom-Json
    if ($result.SubnetResourceId.TrimEnd('/') -eq $outputs.routingSubnetId.value.TrimEnd('/')) {
      $delegationResult = $result
    }
    Write-Log -Level SUCCESS -Message 'Received routing subnet context IDs.'
  }
  else {
    Write-Log -Level REMOTE -Message "[subnet-delegator] $line"
  }
}
Assert-LastExitCode 'Customer routing subnet delegation'
if (-not $delegationResult.PrimaryContextId) { throw 'Subnet delegation returned no matching primary context ID.' }

$newRouters = [Collections.Generic.List[object]]::new()
try {
  Assert-SingleBackendPlacement -Routers $routers -Selected $selected
  foreach ($router in @($selected)) {
    $captured = [Collections.Generic.List[string]]::new()
    try {
      Invoke-ResilientSshCommand -HostAddress $router.HostAddress `
        -Command (Get-RouterCommand -Router $router -AuthToken $delegationResult.PrimaryContextId) `
        -OperationName "$($router.Name) SWIFT routing setup" -TimeoutSeconds $SwiftSetupTimeoutSeconds `
        -CapturedOutput $captured | Out-Null
    }
    finally {
      if ($captured.Contains('__SWIFT_NEW_NC__')) { [void]$newRouters.Add($router) }
    }
    if (-not $captured.Contains('__SWIFT_ROUTER_READY__')) {
      throw "No SWIFT routing readiness marker was returned by $($router.Name)."
    }
  }
}
catch {
  $setupError = $_
  foreach ($router in $newRouters) {
    try {
      Invoke-ResilientSshCommand -HostAddress $router.HostAddress `
        -Command (Get-RouterCommand -Router $router -Cleanup) `
        -OperationName "$($router.Name) failed setup rollback" -TimeoutSeconds 30 | Out-Null
    }
    catch { Write-Log -Level WARN -Message "SWIFT rollback failed on $($router.Name): $($_.Exception.Message)" }
  }
  throw $setupError
}

Write-Log -Level SUCCESS -Message "Sole SWIFT backend $($selected.Ip): $BackendRouter, $($selected.Namespace), VLAN $($selected.Vlan). The other router has no NC."
Write-Host "Cleanup managed SWIFT attachments: & '$PSCommandPath' -ResourceGroupName '$ResourceGroupName' -DeploymentName '$DeploymentName' -CleanupSwift -SshPrivateKeyPath '$privateKeyPath'"

if (-not $SkipThroughputTest) {
  & "$PSScriptRoot\test-throughput.ps1" -ResourceGroupName $ResourceGroupName `
    -DeploymentName $DeploymentName -UdpTargetMbps $UdpTargetMbps -DurationSeconds $DurationSeconds `
    -BackendRouter $BackendRouter -ConnectivityOnly:$ConnectivityOnly -ConnectivityTimeoutSeconds $ConnectivityTimeoutSeconds
}
Write-Log -Level SUCCESS -Message 'SWIFT ILB topology is deployed. Network containers are retained for routing and subsequent tests.'
