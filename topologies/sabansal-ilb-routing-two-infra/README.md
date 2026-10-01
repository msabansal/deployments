# Sabansal ILB routing with two infra VMs

An independent deployment based on `sabansal-ilb-routing`. Endpoint VMs live in
the customer VNet (`10.80.0.0/16`). Both router VMs live in a **separate, unpeered
infra VNet** (`10.30.0.0/16`, router subnet `10.30.0.0/24`). Each router NIC has
exactly one native IP configuration, entirely outside the customer address space.
There is exactly **one SWIFT network container (NC) and one customer backend IP,
`10.80.0.5`**, not an Azure NIC secondary IP. The current/default placement is
router-2 in `swift-ilb-backend2`, VLAN 2. Router-1 has no NC. No `10.80.0.6`
attachment is created or required:

| VM | Native NIC IP | SWIFT IP / ILB backend |
| --- | --- | --- |
| router-1 (infra VM 1) | Primary `10.30.0.4` only | None by default |
| router-2 (infra VM 2) | Primary `10.30.0.5` only | Sole backend `10.80.0.5/32` on VLAN 2 `swift0` in `swift-ilb-backend2` |
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
SWIFT backend remains `10.80.0.5`. Migration retains the existing ILB
resource, moves only its frontend to the new subnet, and updates both UDRs.

`swiftcmd` creates only the selected backend NC attached to the customer router
subnet `10.80.0.0/24`. `-BackendRouter router2` (default) selects
`swift-ilb-backend2`/VLAN 2; `-BackendRouter router1` selects
`swift-ilb-router1`/VLAN 1, matching the original/migration placement.
After CLI creation, this topology's configure script reads the
namespace's default gateway, deletes the initial ipvlan child, moves the exact
host `swiftvlan<VLAN>` interface into the namespace, and renames that VLAN interface
to `swift0`. It restores the `/32` address, permanent gateway neighbor, and
on-link default route. An already-converted attachment is reused only after its
VLAN ID is validated.

The final interface is **VLAN `swift0` inside the selected backend namespace**,
owning only `10.80.0.5/32`. There is no routing VLAN or `swiftvlan1`/`swiftvlan2`
left in either root namespace; the
native host interface retains only its infra address. Neither router has any native
`10.80.*` NIC IP or customer IP in the root network namespace. IPv4 forwarding
must be enabled **inside the active SWIFT namespace**; host forwarding alone is
not sufficient. The inactive host has no NC and its root forwarding counter
must not increase during testing (historical nonzero totals are allowed).
This variant uses the SWIFT migration experiment below rather than the reference
topology's native-NIC backend-IP migration script.

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
  -BackendRouter router2 `
  -UdpTargetMbps 5000 `
  -DurationSeconds 30
```

The default deployment name and resource prefix are
`sabansal-ilb-routing-two-infra`. The original topology and resource group are
not modified. The SSH public key defaults to `~\.ssh\id_ed25519.pub`.
Use `-SkipThroughputTest` to deploy and configure SWIFT without running the UDP
benchmark. Use `-SkipTopologyDeployment` to configure SWIFT and test an existing
deployment without redeploying its Azure resources.
Both deploy and test select placement from `-BackendRouter`, not stale
deployment-output placement metadata. Existing outputs describing router-1
and `.6` do **not** require redeployment to test the current router-2 backend.
Deployment preflights both hosts' managed state, NC IDs, and namespace addresses
before creation. A backend on the other host, legacy `.6`, mismatched state, or
untracked NC is an explicit error, never permission to create a duplicate `.5`.
Use the migration tool for cutover, or explicitly clean up managed attachments
before deploying a different placement. Only the selected host receives an NC.

The deploy script's local tooling defaults are:

| Parameter | Default |
| --- | --- |
| `SwiftBinaryPath` | `Q:\az\Networking-Hybrid-SurgeGuard\AKS-Multitenancy\SwiftCli\bin\Release\net10.0\linux-x64\publish\swiftcmd` |
| `NrpSubnetDelegatorProject` | `Q:\az\Networking-Hybrid-SurgeGuard\AKS-Multitenancy\NrpSubnetDelegatorCli\NrpSubnetDelegatorCli.csproj` |

Override these paths when using a different checkout or published binary.
Subnet delegation and NC creation are performed by `deploy.ps1`, not by the
throughput test. Provisioning inventories both hosts over SSH but creates/reuses
only the selected host's NC. Authentication tokens must not be printed or included in test
diagnostics.

### Deployment output contract

The test requires `infraVnetId`, `customerVnetId`, `customerVnetGuid`,
`routingSubnetId`, and `routingSubnetName`. The routing subnet belongs to the
customer VNet. New deployments default to `backendRouter = router2`,
`routerNamespaceName = swift-ilb-backend2`, `routingVlanId = 2`, and
`routingBackendIp = 10.80.0.5`. Selecting router-1 changes only placement
outputs to `swift-ilb-router1`/VLAN 1. Obsolete `.6` parameters/outputs are
removed; old Azure deployment records may still contain them and are ignored.
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

### Quick current-backend connectivity (no migration)

```powershell
python .\test-connectivity.py
```

This checks the existing sole `10.80.0.5` NC on router-2 in
`swift-ilb-backend2` (VLAN 2), without reattaching the backend, delegating the
subnet, deploying Azure resources, or running a migration. It uses management
SSH to run bidirectional endpoint pings and **fresh, direct in-band TCP and UDP**
iperf connections through the unchanged ILB/UDRs. UDP offers 100 Mbit/s.
Each data test defaults to three seconds, with an eight-second client safety
timeout plus two seconds of TERM-to-KILL grace; SSH connection timeout is five
seconds. Override `--duration`/`--timeout` for a different bounded window and
`--key`, `--router-host`, `--client-host`, `--server-host`, or `--namespace` for
different management access or placement. Use `--output` to save the report.

The runner verifies that the backend host's NC inventory contains exactly the
managed `.5` NC and that its namespace forwarding counter increases. Its
one-shot TCP/UDP listeners on 5203 and temporary private measurement jobs are
cleaned up, while the backend NC and persistent 5201 listener are retained.
For native-NIC, VLAN, effective-route, and inactive-host isolation validation,
use the PowerShell test below.

The verified fresh run reported on 2026-10-02 had bidirectional ping loss of
0%, TCP receive throughput of 6.47747 Gbit/s, UDP receive throughput of
99.91 Mbit/s at 100 Mbit/s offered, and 98,854 forwarded datagrams in the `.5`
namespace. **Fresh TCP connectivity is not proof that an established TCP
connection survives or recovers after backend migration.** That requires the
separate in-band TCP migration experiment.

### Measure a live SWIFT migration

```powershell
python .\test-migration.py `
  --duration 120 `
  --migrate-after 30 `
  --output-directory "$env:TEMP\swift-ilb-migration-results"
```

Requires Python, Azure CLI authentication in the topology's subscription,
OpenSSH, the published Swift CLI, and the subnet delegator checkout. Override
`--key`, `--swift-binary`, or `--delegator-project` for other local paths.
The test reads router public addresses from deployment outputs and endpoint
public addresses from Azure. It starts a dedicated, bounded one-shot VM2 iperf
listener on 5203 with a server duration limit longer than the requested test,
leaving the existing 5201 listener untouched.
By default only iperf's TCP control connection uses authenticated management
SSH forwards through the controller. A uniquely tagged, temporary VM1 OUTPUT
DNAT rule redirects TCP destination `10.80.2.4:5203` to loopback port 5204.
UDP data still traverses the unchanged ILB path. The rule and SSH forwards are
removed on exit. This avoids losing the final iperf statistics when its in-band
TCP control session times out across migration; it does **not** prove that an
existing customer TCP connection survives the cutover. Use `--in-band-control`
to reproduce that control-session behavior instead.
Run `python .\test-migration-unit.py` for the offline coordinator regressions.
The client completion grace defaults to five seconds beyond the data duration
and is configurable with `--completion-grace` (0-30 seconds); forced termination
has a further two-second grace. These client bounds are separate from backend
onboarding/version readiness and do not turn incomplete measurements into
successful results.

To test established TCP connections across the same 120-second window:

```powershell
python .\test-migration.py `
  --protocol tcp `
  --duration 120 `
  --migrate-after 30 `
  --output-directory "$env:TEMP\swift-ilb-tcp-migration-results"
```

TCP uses two unthrottled data streams. Both data and iperf control stay on the
ILB path: the UDP-only SSH control-redirection rule must never redirect TCP
benchmark data. Reports contain TCP retransmissions rather than UDP loss
percentages. The independent echo probe still measures UDP reachability, not
TCP-session recovery. Client and server raw iperf logs are retained even if
the control session times out, so a failed TCP run is not reported as success.

The 2026-10-01 TCP run transferred roughly 8-9 Gbit/s before cutover. Both
client and server intervals show zero progress after approximately 32 seconds,
with no recovery during the remaining 88 seconds of the requested window.
The server eventually reported an idle receive timeout; the client was killed
by the 180-second safety timeout while waiting for completion. Its final
180-second aggregate and zero receiver placeholder are not valid 120-second
throughput results. The independent UDP echo recovered after a 4.600-second
gap, which does not imply recovery of the established TCP connections.

The migration experiment restores the sole `10.80.0.5` backend to router-1. It then sends the
two-stream, aggregate 5-Gbit/s UDP GSRO workload for 120 seconds, migrating
router-1 to router-2 about 30 seconds into the run. The migrated backend uses VLAN 2 in
`swift-ilb-backend2`. No ILB pool or endpoint route is changed. A successful
run leaves `10.80.0.5` on router-2; the ordinary test below defaults to that
placement. There must be no separate `.6` NC.
Before starting the measurement clock it waits, bounded to 30 seconds, for
actual UDP echo delivery through the restored baseline; NC-version readiness
alone is not treated as proof of dataplane convergence. The readiness job has
a separate 40-second orchestration budget.

Source release and destination onboarding use pre-staged, root-private scripts
and SSH sessions opened before traffic starts. The destination is triggered
immediately upon observing the CLI's validated NC-deletion acknowledgement,
before source namespace cleanup. Detached systemd jobs survive the transient
management disconnect; log monitoring reconnects using numbered offsets without
replaying either migration operation. Failed destination onboarding attempts
restore router-1 after first stopping and removing the owned destination NC.
Failures remain failures and retain root-private diagnostics; authentication
scripts are removed.

An independent UDP echo flow samples endpoint-to-endpoint connectivity at
100 Hz during the load and for ten additional seconds. The CSV and JSON
distinguish consecutive lost probes, initial/final loss, late echoes, and
reordering. Flanked loss runs report the last-success-to-first-recovery receive
gap and lost-send span, with 10-ms sampling, scheduling, and RTT uncertainty.
The separate chronological successful-echo gap includes locally missed slots
without classifying them as network loss; a missed scheduled probe cannot
split and conceal a longer period with no observed replies.
These are sampled round-trip observations, not exact fabric downtime. Local
scheduler misses and send errors are recorded separately and explicitly mark
sampling incomplete; they are never counted as network packet loss.
Aggregate iperf loss is not used to calculate the outage. Controller release,
trigger, POST, and readiness timings include SSH/log-observation latency and a
50-ms log polling interval; they are not exact server-side timestamps.

The output directory contains `summary.json`, the raw `iperf.json`,
`controller-timings.json`, `probe-report.json`, and per-probe `probe.csv`.
A temporary 5202 echo server, the 5203 one-shot iperf server, and this experiment's
measurement jobs are stopped after the test; the persistent 5201 listener and
sole backend NC remain intact.
Measurements are also saved when the migration completes but forwarding
isolation fails. Such a run prints the exact counter deltas and exits 2 instead
of claiming success: the source must have no NC, the destination must have
exactly the sole `.5` NC with no `.6`, only its `.5` namespace may carry the
backend's traffic, and neither source nor destination root forwarding may
increase. Probe-only
scheduling misses are a separate, explicit sampling-quality warning.

#### Historical dual-attachment observations on 2026-10-01

The observations below preceded removal of the legacy `.6` attachment and do
not describe the current single-NC architecture.

A complete 120.001-second sender run offered 5.00 Gbit/s and received
3.57 Gbit/s, with 28.38% iperf loss across the whole test. Source release was
observed 31.68 seconds after the load command began. The already-open
destination channel was triggered 0.138 ms after that observation; the NC
creation POST was observed 0.556 seconds later. Full namespace/probe-service
readiness was observed 46.32 seconds after release.

The largest chronological UDP-echo success gap was **5.706 seconds**, bounded
by received probes 3204 and 3774. There were 569 lost-sent probes and no local
missed slots inside that interval. Other intervals did contain scheduling
misses, so the raw report correctly marks overall sampling incomplete. The
gap remains a 100-Hz sampled round-trip observation, with scheduling and RTT
uncertainty, not exact fabric downtime.

**Exclusive routing failed:** the original `10.80.0.6` namespace forwarded
2,930,876 additional kernel datagrams, while the migrated `10.80.0.5`
namespace forwarded only 2,152. Source-root forwarding stayed unchanged.
Both router-2 NCs remained present, the original `10.80.0.6` NC was retained,
router-1 had no NCs, and the ILB pool still contained only `10.80.0.5`.
Therefore the observed recovery must not be described as a verified clean
handoff to the migrated backend. This run intentionally exited 2 and saved
its full measurement evidence.

### Test current connectivity and throughput

For a short connectivity-only check with a five-second reachability deadline:

```powershell
.\test-throughput.ps1 -BackendRouter router2 -ConnectivityOnly -ConnectivityTimeoutSeconds 5
```

This checks bidirectional endpoint ICMP and VM1-to-VM2 TCP/5201 through the
unchanged ILB/UDRs, plus active namespace forwarding and inactive root isolation.
It reuses/starts the persistent iperf listener but skips the UDP load.
For a short UDP measurement:

```powershell
.\test-throughput.ps1 `
  -ResourceGroupName sabansal-ilb-routing-two-infra-rg `
  -BackendRouter router2 `
  -ConnectivityTimeoutSeconds 5 `
  -UdpTargetMbps 5000 `
  -ParallelStreams 2 `
  -DurationSeconds 10
```

The test uses Azure VM Run Command (`RunShellScript`), with no SSH session or NC
creation. It verifies each router NIC has exactly its one expected primary infra
IP and an infra-VNet subnet, and rejects native customer/backend IPs. The sole
IP-based ILB backend must be `10.80.0.5` mapped to the customer VNet, with no
NIC-based backends. Guest checks require no root customer IPs and verify
the selected SWIFT namespace, **VLAN `swift0` with the selected VLAN ID**,
sole `10.80.0.5/32`, and namespace IPv4 forwarding. NC inventory must contain
exactly one NC on the active host and zero on the inactive host; any `.6` or
other customer attachment is rejected. Root routing VLANs and
`swiftvlan1`/`swiftvlan2` must be absent; the old ipvlan layout is rejected.
Both endpoint effective routes must
point to the deployment's `loadBalancerFrontendIp` (`10.80.3.10` in subnet `ilb`).

The UDP GSRO benchmark defaults to **5000 Mbps aggregate, 30 seconds, two
streams**, with 1380-byte datagrams. It sends traffic from VM1 to VM2 and reads
the active backend's exact `Ip: ForwDatagrams` counter through
`ip netns exec swift-ilb-backend2 ... /proc/net/snmp` by default, never its host
counter. That namespace counter must increase. The inactive host's root counter
must stay unchanged because it has no namespace/NC. `-BackendRouter router1`
instead measures `swift-ilb-router1` and router-2's inactive root.
Reports include throughput, packet loss, jitter,
and VM1 CPU utilization. Nonzero guest/CLI exits, failed Azure statuses, and
missing or duplicate completion markers are treated as failures even if Azure
CLI reports success. Stderr from a successful guest is explicitly emitted as a
warning, without contaminating the returned stdout JSON. Failure diagnostics
include the VM and operation, Azure status codes, CLI and guest exit status,
guest stdout/stderr, and CLI stderr; authentication material is redacted.
Client failures also identify the failing shell command and include the
iperf JSON report when the client has started.

Ordinary connectivity defaults to five seconds; layout guest scripts are
bounded to 30 seconds, listener/counter scripts to 15 seconds. The iperf
connection timeout uses the connectivity deadline, with a safety limit of
duration + connectivity timeout + 10 seconds; its guest wrapper adds another
10 seconds. Thus a 10-second/five-second test has a 35-second guest budget,
not 180/600 seconds. Azure Action Run Command dispatch latency is separate
from these guest execution limits. SWIFT setup/version/probe readiness uses
the independent `-SwiftSetupTimeoutSeconds` (120 by default); migration
readiness settings are owned by the migration tool, not throughput timeouts.

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

The sole backend NC, VLAN, and namespace are **retained after testing**, including a
failed throughput test, so the selected router can continue routing. Cleanup is performed
only when explicitly requested:

```powershell
.\deploy.ps1 `
  -ResourceGroupName sabansal-ilb-routing-two-infra-rg `
  -CleanupSwift
```

Cleanup inventories both hosts and removes only matching topology-managed
attachments: router-1 `swift-ilb-router1`/VLAN 1, router-2
`swift-ilb-backend2`/VLAN 2, and the legacy router-2
`swift-ilb-router2`/VLAN 1 `.6` attachment **if its managed state is found**.
Untracked namespaces and mismatched managed state are refused; unrelated NCs
are not deleted. Cleanup removes each exact probe unit/script, NC, namespace,
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
