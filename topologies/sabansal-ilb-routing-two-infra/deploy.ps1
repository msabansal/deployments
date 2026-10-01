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
      --parameters "location=$Location" "adminPublicKey=$publicKey" "vmSize=$VmSize" `
      --output none
    Assert-LastExitCode 'Azure topology deployment'
  }
}

$outputs = az deployment group show `
  --resource-group $ResourceGroupName --name $DeploymentName `
  --query properties.outputs -o json | ConvertFrom-Json
Assert-LastExitCode 'Reading topology outputs'

foreach ($name in @('infraVnetId', 'customerVnetId', 'customerVnetGuid', 'routingSubnetId', 'routingSubnetName',
    'routingBackendIp', 'routerNamespaceName', 'routingVlanId', 'router1PublicIp',
    'router2PublicIp', 'router2SwiftIp', 'router2NamespaceName', 'router2VlanId')) {
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
    Namespace = $outputs.routerNamespaceName.value
    Ip = $outputs.routingBackendIp.value
    Vlan = $outputs.routingVlanId.value
  },
  [pscustomobject]@{
    Name = $outputs.router2Name.value
    HostAddress = $outputs.router2PublicIp.value
    Namespace = $outputs.router2NamespaceName.value
    Ip = $outputs.router2SwiftIp.value
    Vlan = $outputs.router2VlanId.value
  }
)

if ($CleanupSwift) {
  $failures = @()
  foreach ($router in $routers) {
    try {
      Invoke-ResilientSshCommand -HostAddress $router.HostAddress `
        -Command (Get-RouterCommand -Router $router -Cleanup) `
        -OperationName "$($router.Name) Swift cleanup" | Out-Null
    }
    catch { $failures += "$($router.Name): $($_.Exception.Message)" }
  }
  if ($failures.Count) { throw ($failures -join "`n") }
  Write-Log -Level SUCCESS -Message 'Both SWIFT NCs, namespaces, and VLANs were removed. Azure resources and the subnet delegation were retained.'
  return
}

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
  foreach ($router in $routers) {
    Write-Log -Level STEP -Message "Installing swiftcmd on $($router.Name)."
    $copied = $false
    $remoteBinary = "/tmp/swiftcmd-$([guid]::NewGuid().ToString('N'))"
    for ($attempt = 1; $attempt -le 12; $attempt++) {
      scp -q -i $privateKeyPath -o BatchMode=yes -o StrictHostKeyChecking=accept-new `
        -o ConnectTimeout=10 $swiftBinary "azureuser@$($router.HostAddress):$remoteBinary"
      if ($LASTEXITCODE -eq 0) { $copied = $true; break }
      if ($attempt -lt 12) { Start-Sleep -Seconds 10 }
    }
    if (-not $copied) { throw "Could not copy swiftcmd to $($router.Name)." }
    ssh -i $privateKeyPath -o BatchMode=yes -o StrictHostKeyChecking=accept-new `
      -o ConnectTimeout=10 "azureuser@$($router.HostAddress)" `
      "sudo install -m 0755 '$remoteBinary' /usr/local/bin/swiftcmd && rm -f '$remoteBinary'"
    Assert-LastExitCode "Installing swiftcmd on $($router.Name)"

    $captured = [Collections.Generic.List[string]]::new()
    try {
      Invoke-ResilientSshCommand -HostAddress $router.HostAddress `
        -Command (Get-RouterCommand -Router $router -AuthToken $delegationResult.PrimaryContextId) `
        -OperationName "$($router.Name) SWIFT routing setup" -TimeoutSeconds 600 `
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
        -OperationName "$($router.Name) failed setup rollback" | Out-Null
    }
    catch { Write-Log -Level WARN -Message "SWIFT rollback failed on $($router.Name): $($_.Exception.Message)" }
  }
  throw $setupError
}

Write-Log -Level SUCCESS -Message "Router 1: $($routers[0].HostAddress), SWIFT $($routers[0].Ip) (sole ILB backend). Router 2: $($routers[1].HostAddress), SWIFT $($routers[1].Ip) (not in backend pool)."
Write-Host "Cleanup both SWIFT attachments: & '$PSCommandPath' -ResourceGroupName '$ResourceGroupName' -DeploymentName '$DeploymentName' -CleanupSwift -SshPrivateKeyPath '$privateKeyPath'"

if (-not $SkipThroughputTest) {
  & "$PSScriptRoot\test-throughput.ps1" -ResourceGroupName $ResourceGroupName `
    -DeploymentName $DeploymentName -UdpTargetMbps $UdpTargetMbps -DurationSeconds $DurationSeconds
}
Write-Log -Level SUCCESS -Message 'SWIFT ILB topology is deployed. Network containers are retained for routing and subsequent tests.'
