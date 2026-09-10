# VNet-to-VNet ExpressRoute deployment

This Bicep deployment implements the topology from the Azure Wiki page:

- simulated on-premises VNet with an ExpressRoute gateway
- Azure VNet with an ExpressRoute gateway
- ExpressRoute circuit using provider `Juniper1` from `main.bicepparam`
- peering location `Azure` from `main.bicepparam`
- Premium metered-data circuit SKU
- Azure private peering
- one connection from each VNet gateway to the circuit
- optional latest Azure Linux test VM in each VNet
- Standard public IP on each optional test VM
- workload-subnet NSGs allowing `CorpnetPublic`, `CorpnetSAW`, and VNet traffic while denying all other inbound access

The defaults use zone-redundant `ErGw1AZ` ExpressRoute gateways with FastPath
disabled. To enable FastPath, select a supported gateway SKU (`ErGw3AZ` or
`UltraPerformance`) and set `enableFastPath = true`. See the
[FastPath gateway requirements](https://learn.microsoft.com/en-us/azure/expressroute/about-fastpath#gateway-skus).

## Files

- `main.bicep` - deployment entry point and gateway connections
- `modules/vnet-with-expressroute-gateway.bicep` - VNet, subnets, public IP, and gateway
- `modules/expressroute-circuit.bicep` - circuit and optional Azure private peering
- `modules/test-vm.bicep` - private connectivity-test VM using the Azure Linux OS
- `main.bicepparam` - editable deployment values
- `deploy.ps1` - deployment wrapper that reads the SSH key from `~\.ssh\id_ed25519.pub` by default
- `scripts/install-network-tools.sh` - shared guest installer embedded by Bicep and used by the updater
- `scripts/NetworkTools.Common.ps1` - NIC discovery and checked, bounded Azure Run Command helper
- `update-network-tools.ps1` - install tooling on the two existing VMs without redeploying networking
- `test-connectivity.ps1` - bidirectional ping and TCP throughput using short-lived, isolated servers

## Deploy

Deploy without test VMs:

```powershell
.\deploy.ps1 -ResourceGroupName <resource-group> -Location <location>
```

To reuse existing VNets while still deploying their NSGs, ExpressRoute gateways, optional test VMs, and circuit connections:

```powershell
.\deploy.ps1 -ResourceGroupName <resource-group> -Location <location> -SkipVirtualNetworks
```

The equivalent Bicep parameter is `deployVirtualNetworks = false`.

The existing VNets must use the configured names and contain both a `workload` subnet and a `GatewaySubnet` with the address prefixes supplied in `main.bicepparam`.

To deploy only VM-related resources into existing VNets and skip all gateways, circuit, peering, and connections:

```powershell
.\deploy.ps1 -ResourceGroupName <resource-group> -Location <location> -VmsOnly
```

For other combinations, use `-SkipGatewaysAndCircuit`, `-SkipVirtualNetworks`, and `-DeployTestVms`. The equivalent Bicep control is `deployGatewaysAndCircuit`.

The deployment creates private peering and both gateway connections in the same deployment, so it requires the lab provider to provision the circuit automatically.
The parameter file selects `Juniper1` / `Azure` for the EUAP lab. Deploying
`main.bicep` without that parameter file retains its original `bvtazureixp03` /
`Noida2` defaults. Confirm provider availability in the target subscription.

The `peerAsn`, `vlanId`, and `/30` peer prefixes are deployment-specific values. Confirm them before deploying.

## Optional test VMs

To deploy one Azure Linux VM in each workload subnet, use:

```powershell
.\deploy.ps1 -ResourceGroupName <resource-group> -Location <location> -DeployTestVms
```

The script reads the administrator key from `~\.ssh\id_ed25519.pub`. Override it with `-SshPublicKeyPath <path>`.

The VMs use the latest `MicrosoftAzureLinux:azurelinux-4:4` image and have both private and Standard public IP addresses. Their workload-subnet NSGs allow inbound traffic from `CorpnetPublic`, `CorpnetSAW`, and the `VirtualNetwork` service tag, then deny all other inbound traffic. The deployment outputs both private and public IP addresses.

The VM uses the image's supported default security type rather than Trusted Launch.

Each VM runs the `install-network-tools` Custom Script extension after provisioning.
The shared installer requires `iperf3`, `tcpdump`, `iproute`, `iputils`, `traceroute`,
`nmap-ncat`, `bind-utils`, `python3`, and `coreutils`, installed using `tdnf` or
`dnf`. Package failures fail provisioning or updating explicitly.

Guest firewall additions allow only TCP/UDP ports **5201-5210** and ICMP from the
peer workload subnet during deployment, or the peer's current NIC IPv4 address
(`/32`) during an in-place update. With active firewalld, rich rules are added to
the peer-facing interface's zone (default zone if unassigned), both persistently
and at runtime. With bare iptables, an `er-network-tools-firewall` systemd oneshot
service reapplies only these INPUT additions on boot. Existing rules are retained;
an update does not remove broader peer-subnet rules previously installed by
deployment. No firewall is installed if none exists. Native nftables INPUT
policies other than the iptables compatibility chain are rejected explicitly and
require administrator integration. If firewalld uses source-based zones, ensure
the peer is assigned to the same zone as the peer-facing interface.

The installer never flushes rules, alters FORWARD/default policies, disables a
firewall, or changes NSGs. No permanent iperf3 server is created. The VM module's
optional `peerWorkloadSubnetPrefix` defaults to empty (install tools without
firewall changes); `main.bicep` passes each VM the opposite workload subnet.

## Update existing VMs without redeployment

Requires PowerShell, Azure CLI sign-in, VM/NIC read permissions and permission to
invoke VM Run Command. The VM agent must be healthy and package repositories
reachable. Run from this topology directory:

```powershell
$subscriptionId = '<subscription-id>'
.\update-network-tools.ps1 -ResourceGroupName sabansal-ertest1 -SubscriptionId $subscriptionId
.\update-network-tools.ps1 -ResourceGroupName sabansal-ertest2 -SubscriptionId $subscriptionId
```

These two invocations update the four existing VMs, without modifying gateways,
circuits, connections, or FastPath settings. Each invocation first resolves and
checks both expected Linux VMs, their NICs, and their workload subnets, then updates
them sequentially. If one installation fails, the script stops; it does not roll
back an already updated VM. Fix the reported error and rerun.

Both scripts accept `-NamePrefix` (default `vnet-to-vnet-er`) and optional
`-SubscriptionId`; if omitted, Azure CLI's current subscription is used. VM names
are `<prefix>-onprem-vm` and `<prefix>-azure-vm`. Private IPs come from actual NIC
configurations, not deployment names or outputs, so older deployments work.

## Test connectivity

```powershell
# Each invocation pings in both directions. TCP defaults to on-premises -> Azure.
.\test-connectivity.ps1 -ResourceGroupName sabansal-ertest1 -SubscriptionId $subscriptionId
.\test-connectivity.ps1 -ResourceGroupName sabansal-ertest1 -SubscriptionId $subscriptionId -Reverse
.\test-connectivity.ps1 -ResourceGroupName sabansal-ertest2 -SubscriptionId $subscriptionId
.\test-connectivity.ps1 -ResourceGroupName sabansal-ertest2 -SubscriptionId $subscriptionId -Reverse

$result = .\test-connectivity.ps1 -ResourceGroupName sabansal-ertest2 `
  -SubscriptionId $subscriptionId -DurationSeconds 15 -ParallelConnections 4 -Port 5202 -PassThru
$result | Format-List
```

Duration defaults to 15 seconds (5-120 allowed), streams to 4 (1-32 allowed), and
port to 5201 (5201-5210 allowed). `-Reverse` uses iperf3 reverse mode: the Azure VM
sends data to the on-premises VM over a connection initiated by the on-premises
client. The script reports ping loss/average RTT, sent/received throughput, and TCP
retransmits. Ping must receive a response in each direction before throughput is
reported; partial packet loss is shown rather than hidden. This is a TCP test;
the UDP ports are available for manual diagnostics, not an automated UDP test.

A unique systemd transient unit owns each server. Startup checks for port
conflicts and verifies the listening PID. Cleanup always targets only that unit,
including after failed startup or tests; other iperf servers are never killed.
Each server expires independently after the requested duration plus 300 seconds
(at most 420 seconds, plus a 5-second stop grace), even if the local caller is
terminated. Local cleanup failures are surfaced. Run Command calls also impose
remote timeouts and verify a unique remote exit marker; Azure's success envelope
alone is not trusted. Reports are compacted on the VM to fit the 4 KB output limit.
Allow additional time for sequential Azure Run Command operations beyond the
requested measurement duration. Do not run tests/updates concurrently on the same
VMs; use another port if a manually managed server occupies the default.

**Reachability, throughput, and traceroute do not prove ExpressRoute or FastPath
traversal.** Validate effective routing and provider/gateway telemetry separately.
VM size, CPU, NIC limits, streams, and circuit limits can all affect throughput;
these scripts do not change acceleration or gateway configuration.
