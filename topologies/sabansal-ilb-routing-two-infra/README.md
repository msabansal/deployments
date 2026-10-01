# Sabansal ILB routing with two infra VMs

An independent deployment based on `sabansal-ilb-routing`. Endpoint VMs live in
the customer VNet (`10.80.0.0/16`). Both router VMs live in a **separate, unpeered
infra VNet** (`10.30.0.0/16`, router subnet `10.30.0.0/24`). Each router NIC has
exactly one native IP configuration, entirely outside the customer address space.
Each router also has a customer-subnet IP supplied by its own SWIFT network
container (NC), not an Azure NIC secondary IP. Of those two SWIFT IPs, there is
only **one ILB routing backend**, `10.80.0.5`:

| VM | Native NIC IP | SWIFT IP / ILB backend |
| --- | --- | --- |
| router-1 (infra VM 1) | Primary `10.30.0.4` only | `10.80.0.5/32` on `swift0` in `swift-ilb-router1`; sole ILB backend |
| router-2 (infra VM 2) | Primary `10.30.0.5` only | `10.80.0.6/32` on `swift0` in `swift-ilb-router2`; excluded from ILB pool |
| VM1 | `10.80.1.4` | None |
| VM2 | `10.80.2.4` | None |

VM1 and VM2 have symmetric UDRs pointing at ILB frontend `10.80.3.10` in the
separate customer-VNet `ilb` subnet (`10.80.3.0/24`).
The internal Standard Load Balancer uses HA Ports with floating IP enabled and
an IP-based pool containing only `10.80.0.5`, with administrative state `Up`.

The delegated customer `router` subnet (`10.80.0.0/24`) contains **no native
Azure resources**: neither router NICs nor the ILB frontend belong to it.
Azure rejects the NRP service association link (SAL) PUT with HTTP 400
`InUseSubnetCannotBeUpdatedWithServiceAssociationLinks` when the ILB frontend
occupies that subnet. Keeping the frontend in `ilb` allows delegation while the
SWIFT IPs remain `10.80.0.5` and `10.80.0.6`. Migration retains the existing ILB
resource, moves only its frontend to the new subnet, and updates both UDRs.

`swiftcmd` creates an NC on each router attached to the customer router subnet
`10.80.0.0/24`. Both use VLAN 1 on **separate hosts**, so the VLAN IDs do not
conflict. After CLI creation, this topology's configure script reads the
namespace's default gateway, deletes the initial ipvlan child, moves the exact
host `swiftvlan1` interface into the namespace, and renames that VLAN interface
to `swift0`. It restores the `/32` address, permanent gateway neighbor, and
on-link default route. An already-converted attachment is reused only after its
VLAN ID is validated.

The final interfaces are **VLAN `swift0` inside `swift-ilb-router1` and
`swift-ilb-router2`**, owning `10.80.0.5/32` and `10.80.0.6/32`, respectively.
There is no routing VLAN or `swiftvlan1` left in either root namespace; the
native host interface retains only its infra address. Neither router has any native
`10.80.*` NIC IP or customer IP in the root network namespace. IPv4 forwarding
must be enabled **inside both SWIFT namespaces**; host forwarding alone is not
sufficient. Router-2 receives no ILB-routed traffic and its SWIFT namespace forwarding
counter stays zero.
This variant does not include the reference topology's backend-IP migration script.

This topology-local conversion is necessary for **ILB floating-IP transit**.
The load balancer preserves the endpoint destination: for example, a SYN from
`10.80.1.4` to `10.80.2.4` arrives with destination `10.80.2.4`, not the router's
`10.80.0.5`. An ipvlan-L2 child owning only the router IP does not demultiplex that
transit packet into its namespace, leaving it on the root VLAN. Moving the VLAN
itself into the routing namespace delivers those preserved-destination packets
to namespace forwarding. This does not change the general Swift CLI behavior.

All four VMs use Azure Linux 4 and default to `Standard_D2als_v7`, with NVMe
OS disks, Accelerated Networking, public SSH addresses, and CorpNet NSG access.
Router NICs enable Azure IP forwarding; guest configuration enables IPv4
forwarding and disables reverse-path filtering and redirects.

## Deploy

```powershell
.\deploy.ps1 `
  -ResourceGroupName sabansal-ilb-routing-two-infra-rg `
  -Location westus3 `
  -UdpTargetMbps 5000 `
  -DurationSeconds 30
```

The default deployment name and resource prefix are
`sabansal-ilb-routing-two-infra`. The original topology and resource group are
not modified. The SSH public key defaults to `~\.ssh\id_ed25519.pub`.
Use `-SkipThroughputTest` to deploy and configure SWIFT without running the UDP
benchmark. Use `-SkipTopologyDeployment` to configure SWIFT and test an existing
deployment without redeploying its Azure resources.

The deploy script's local tooling defaults are:

| Parameter | Default |
| --- | --- |
| `SwiftBinaryPath` | `Q:\az\Networking-Hybrid-SurgeGuard\AKS-Multitenancy\SwiftCli\bin\Release\net10.0\linux-x64\publish\swiftcmd` |
| `NrpSubnetDelegatorProject` | `Q:\az\Networking-Hybrid-SurgeGuard\AKS-Multitenancy\NrpSubnetDelegatorCli\NrpSubnetDelegatorCli.csproj` |

Override these paths when using a different checkout or published binary.
Subnet delegation and NC creation are performed by `deploy.ps1`, not by the
throughput test. Each host's NC is created through a separate persistent SSH
session. Authentication tokens must not be printed or included in test
diagnostics.

### Deployment output contract

The test requires `infraVnetId`, `customerVnetId`, `customerVnetGuid`,
`routingSubnetId`, and `routingSubnetName`. The routing subnet belongs to the
customer VNet. Routing outputs are `routerNamespaceName = swift-ilb-router1`,
`routingVlanId = 1`, and `routingBackendIp = 10.80.0.5`.
Router-2 outputs are `router2SwiftIp = 10.80.0.6`,
`router2NamespaceName = swift-ilb-router2`, and `router2VlanId = 1`.
The retained `router1SecondaryIp` output is a compatibility alias for
`routingBackendIp` only: **it does not describe a native secondary NIC IP**.
`router1PrimaryIp` and `router2PrimaryIp` are `10.30.0.4` and `10.30.0.5`.
Existing router name, NIC name, and public IP outputs (`router1Name`,
`router2Name`, `router1NicName`, `router2NicName`, `router1PublicIp`,
`router2PublicIp`), endpoint name/NIC/private IP/subnet-prefix outputs, and
load-balancer name/frontend/pool outputs remain available. The
`loadBalancerFrontendIp` output now identifies `10.80.3.10`; the test uses that
output for route validation and reporting rather than hardcoding a frontend IP.

## Validate and test

```powershell
.\test-throughput.ps1 `
  -ResourceGroupName sabansal-ilb-routing-two-infra-rg `
  -UdpTargetMbps 5000 `
  -ParallelStreams 2 `
  -DurationSeconds 30
```

The test uses Azure VM Run Command (`RunShellScript`), with no SSH session or NC
creation. It verifies each router NIC has exactly its one expected primary infra
IP and an infra-VNet subnet, and rejects native customer/backend IPs. The sole
IP-based ILB backend must be `10.80.0.5` mapped to the customer VNet, with no
NIC-based backends. Guest checks require no root customer IPs and verify
both SWIFT namespaces, their respective **VLAN `swift0` interfaces with ID 1**
and `/32` addresses, and namespace IPv4 forwarding. Root routing VLANs and
`swiftvlan1` must be absent; the old ipvlan layout is rejected. Router-2's
`10.80.0.6` must not appear in the ILB pool. Both endpoint effective routes must
point to the deployment's `loadBalancerFrontendIp` (`10.80.3.10` in subnet `ilb`).

The UDP GSRO benchmark defaults to **5000 Mbps aggregate, 30 seconds, two
streams**, with 1380-byte datagrams. It sends traffic from VM1 to VM2 and reads
router-1's exact `Ip: ForwDatagrams` counter through
`ip netns exec swift-ilb-router1 ... /proc/net/snmp`, never router-1's host
counter. Router-1's namespace counter must increase. Router-2's counter is read
through `ip netns exec swift-ilb-router2 ... /proc/net/snmp`, never its host
counter, and must be zero before and after the test. Reports include throughput, packet loss, jitter,
and VM1 CPU utilization. Nonzero guest/CLI exits, failed Azure statuses, and
missing or duplicate completion markers are treated as failures even if Azure
CLI reports success. Stderr from a successful guest is explicitly emitted as a
warning, without contaminating the returned stdout JSON. Failure diagnostics
include the VM and operation, Azure status codes, CLI and guest exit status,
guest stdout/stderr, and CLI stderr; authentication material is redacted.
Client failures also identify the failing shell command and include the
iperf JSON report when the client has started.

These are transient **Action Run Command** calls using
`az vm run-command invoke --command-id RunShellScript`, not named Managed Run
Command resources. VM names come from deployment outputs: by default,
`sabansal-ilb-routing-two-infra-vm1` (UDP client),
`sabansal-ilb-routing-two-infra-vm2` (persistent server), and
`sabansal-ilb-routing-two-infra-router1` / `-router2` (layout and namespace
counter checks). Each invocation uploads an LF-normalized temporary script and
wraps it with a unique guest exit marker. VM1's client targets `10.80.2.4:5201`
and stores the raw iperf JSON at `/tmp/ilb-routing-udp.json`.

An existing iperf3 listener is reused only if its process executable matches the
installed iperf3 binary. Otherwise a persistent server is started on VM2.
An incompatible existing listener fails the test; no processes are killed by
name. The test does not stop servers after completion or failure.

## Explicit SWIFT cleanup

Both routers' NCs, VLANs, and namespaces are **retained after testing**, including a
failed throughput test, so router-1 can continue routing. Cleanup is performed
only when explicitly requested:

```powershell
.\deploy.ps1 `
  -ResourceGroupName sabansal-ilb-routing-two-infra-rg `
  -CleanupSwift
```

Cleanup removes each router's exact probe unit and probe script, NC, namespace,
and VLAN. The probe is stopped before deletion. CLI namespace deletion also
deletes the VLAN moved into that namespace; the CLI tolerates its absence from
the root namespace. Cleanup **retains the SAL and all Azure objects**, including the VNets,
subnets, ILB, NICs, and VMs; it does not redeploy the topology. The ILB routing
path will no longer work until SWIFT is configured again. To restore it against
the existing Azure topology, run `.\deploy.ps1 -SkipTopologyDeployment`.

## Router reboot recovery

SWIFT namespaces and VLAN interfaces are runtime configuration and are **not
automatically recreated after a router reboot**. Persisted NC state remains in
root-only files, but that state alone does not restore the namespace or routing.
After a reboot, explicitly clean up the recorded state and runtime resources,
then recreate SWIFT against the retained Azure topology:

```powershell
.\deploy.ps1 `
  -ResourceGroupName sabansal-ilb-routing-two-infra-rg `
  -CleanupSwift

.\deploy.ps1 `
  -ResourceGroupName sabansal-ilb-routing-two-infra-rg `
  -SkipTopologyDeployment
```
