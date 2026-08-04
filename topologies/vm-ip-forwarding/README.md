# OS packet forwarding through a router VM

Two Linux endpoint VMs exchange traffic with each other, and every packet between them is
forced through a third VM that forwards it using plain operating-system routing. No Azure
NVA appliance, load balancer, or gateway is involved — only user-defined routes plus IP
forwarding inside the guest.

```
        endpoint-a subnet 10.30.1.0/24          endpoint-b subnet 10.30.2.0/24
        +---------------------------+           +---------------------------+
        |  fwd-endpoint-a           |           |  fwd-endpoint-b           |
        |  Azure Linux 4            |           |  Azure Linux 4            |
        |  iperf3 / tcpdump         |           |  iperf3 / tcpdump         |
        +-------------+-------------+           +-------------+-------------+
                      |  UDR: 10.30.2.0/24 -> 10.30.0.4       |  UDR: 10.30.1.0/24 -> 10.30.0.4
                      |                                       |
                      +------------------+--------------------+
                                         |
                        router subnet 10.30.0.0/24
                        +----------------------------------+
                        |  fwd-router-lnx / fwd-router-win  |
                        |  static IP 10.30.0.4              |
                        |  Accelerated Networking enabled   |
                        |  Azure IP forwarding enabled      |
                        |  OS-level IP forwarding enabled   |
                        +----------------------------------+
```

## What gets deployed

- One VNet with three subnets: `router`, `endpoint-a`, `endpoint-b`
- A route table on each endpoint subnet whose only route sends the *other* endpoint subnet
  to the router VM as a `VirtualAppliance` next hop
- Two Azure Linux 4 endpoint VMs with `iperf3`, `tcpdump`, `traceroute`, and `ncat` installed
- One router VM, either Azure Linux 4 or Windows Server 2022, with
  - Accelerated Networking on the NIC
  - Azure `enableIPForwarding` on the NIC, so Azure does not drop transit packets
  - guest-OS forwarding: `net.ipv4.ip_forward` on Linux, `IPEnableRouter` plus per-interface
    `Set-NetIPInterface -Forwarding Enabled` on Windows
- NSGs allowing `CorpnetPublic`, `CorpnetSAW`, the VNet-wide test port range, and
  `VirtualNetwork`, then denying all other inbound traffic
- Guest firewall rules opening TCP and UDP `5000-6000` and ICMP echo on every VM
- A Standard public IP on every VM for management access

Both the Azure NIC flag and the guest-OS setting are required. The NIC flag only tells Azure
to allow traffic whose destination IP is not the VM; the actual forwarding decision is made
by the operating system.

## Files

- `main.bicep` - entry point that wires the network and the three VMs together
- `main.bicepparam` - editable deployment values
- `modules/network.bicep` - VNet, subnets, NSGs, and the two route tables
- `modules/linux-vm.bicep` - Azure Linux 4 VM used for both endpoints and the Linux router
- `modules/windows-router-vm.bicep` - Windows Server 2022 router VM
- `deploy.ps1` - deployment wrapper that reads the SSH key from `~\.ssh\id_ed25519.pub`
- `test-connectivity.ps1` - iperf3 throughput test between the endpoints, through the router
- `test-redeploy-loop.ps1` - repeatedly redeploys the router VM and re-runs the throughput test
- `test-fleet.ps1` - deploys N copies of the topology and tests them all in parallel
- `resize-router.ps1` - changes the SKU of a deployed router VM
- `diagnose.ps1` - inspects, and optionally repairs, forwarding state on a deployed router VM

## Deploy

Linux router (default):

```powershell
.\deploy.ps1 -ResourceGroupName <resource-group> -Location <location>
```

Windows Server 2022 router (the script prompts for the administrator password):

```powershell
.\deploy.ps1 -ResourceGroupName <resource-group> -Location <location> -RouterOs WindowsServer2022
```

Override the SSH key with `-SshPublicKeyPath <path>`. The endpoint VMs are always Azure
Linux 4 and always use SSH key authentication.

Override the router size with `-RouterVmSize <sku>`, for example to deploy on an older
hardware generation, and add `-ResizedRouterVmSize <sku>` to move it to another size once the
deployment finishes:

```powershell
.\deploy.ps1 -ResourceGroupName <resource-group> -Location <location> -RouterVmSize Standard_D2s_v6
```

The size must support Accelerated Networking and must boot from NVMe, which means a v6 size or
newer. See the resize section for why the whole topology is pinned to one disk controller.

The deployment outputs the private and public IP of every VM along with the configured test
port range.

## Verify forwarding

### Automated throughput test

`test-connectivity.ps1` runs the whole verification end to end: it starts an iperf3 server on
endpoint B, then runs a single script on endpoint A that first checks the next hop towards
endpoint B and only then drives a parallel-stream test. The path check and the transfer are
deliberately in the same script, so if the traffic is not going through the router the test
fails instead of reporting a throughput number for a path that bypassed it.

```powershell
.\test-connectivity.ps1 -ResourceGroupName <resource-group>
```

To deploy and test in one step:

```powershell
.\deploy.ps1 -ResourceGroupName <resource-group> -Location <location> -RunConnectivityTest
```

Useful switches:

| Switch | Purpose |
| --- | --- |
| `-ParallelConnections <n>` | Number of concurrent TCP streams. Defaults to 8. |
| `-DurationSeconds <n>` | Test length. Defaults to 60. |
| `-Reverse` | Measure server-to-client instead of client-to-server. |
| `-Port <n>` | iperf3 port. Defaults to 5201, which is inside the open `5000-6000` range. |
| `-SkipPathCheck` | Do not fail when the next hop is not the router. |
| `-PassThru` | Return the result as an object as well as printing the summary. |

Sample output:

```
================ throughput summary ================
  path                 : 10.30.1.4 -> 10.30.0.4 -> 10.30.2.4
  first hop verified   : 10.30.0.4
  direction            : client to server
  parallel streams     : 8
  duration             : 60.0 seconds
  bytes sent           : 51.89 GB
  throughput sent      : 7.43 Gbits/sec
  throughput received  : 7.43 Gbits/sec
  TCP retransmits      : 82,185
  client CPU (sender)  : 19.5 %
  server CPU (receiver): 63.0 %
  datagrams forwarded   : 1,923,331
  the router forwarded the traffic in its own IP stack.
====================================================
```

Two independent things confirm the path. The first-hop check gates the test before any traffic
is sent, and, when the router runs Linux, the kernel's `ForwDatagrams` counter from
`/proc/net/snmp` is sampled either side of the test. A counter that does not move fails the
run. The counter line is absent for a Windows router, which has no equivalent that is as cheap
to read.

Do not try to prove this with `tcpdump` on the router. With Accelerated Networking the virtual
function carries the traffic, and a capture on the synthetic interface, or on `any`, reports
zero packets while the router is forwarding at line rate.

### Single-instance loop

`test-redeploy-loop.ps1` owns everything that happens to one resource group. It can deploy the
topology, resize the router to a different SKU before anything is measured, and then loop: run
the throughput test, compare the result with a baseline, and change the router VM before going
round again. While the result stays at or above 80 percent of the baseline it keeps going, and
it stops on the first iteration that falls short, which is the placement worth investigating.

There is also an absolute floor, 100 Mbits/sec by default, checked before the baseline is set. A
percentage threshold alone cannot catch a run that was already broken on its first iteration,
because that first measurement becomes the baseline and everything after it compares favourably.

A run left going indefinitely would otherwise print nothing between the per-iteration lines and
the summary it reaches only when it stops. Every ten iterations it prints a progress summary -
the average, minimum and maximum throughput so far, the router change count and the table of
results - and rewrites `-ResultCsvPath`, so the results of a long run survive an interruption.
The fleet gives each instance a CSV next to its log automatically.

```powershell
.\test-redeploy-loop.ps1 -ResourceGroupName <resource-group>
```

| Switch | Purpose |
| --- | --- |
| `-Deploy` | Deploy the topology first. Requires `-Location`. Without it the resource group must already exist. |
| `-RouterChange <mode>` | What happens to the router between iterations: `Redeploy` (default), `Recreate`, or `None`. |
| `-IterationsBeforeChange <m>` | Successful iterations between router changes. Defaults to 1. |
| `-BaselineGbps <n>` | Compare against a known figure instead of measuring one on the first iteration. |
| `-ThresholdPercent <n>` | Acceptance threshold. Defaults to 80. |
| `-MinimumMbps <n>` | Absolute throughput floor in Mbits/sec, checked before the baseline is set. Defaults to 100. Set to 0 to disable. |
| `-MaxIterations <n>` | Stop after this many iterations. Defaults to 0, meaning run until a failure. |
| `-RouterTimeoutMinutes <n>` | How long to wait for the router VM after a redeploy or resize. Defaults to 20. |
| `-InitialRouterVmSize <sku>` | The SKU router VMs are created on, by `-Deploy` and by a `Recreate`. |
| `-ResizedRouterVmSize <sku>` | Resize the router to this SKU as soon as it is created, before anything is measured. |
| `-ResultCsvPath <path>` | Write the per-iteration results to CSV. |
| `-SummaryEveryIterations <n>` | Print a progress summary and flush the CSV every n iterations. Defaults to 10. Set to 0 to only summarise at the end. |
| `-PassThru` | Return the result object instead of exiting. |

The two router change modes answer different questions. `Redeploy` uses `az vm redeploy`, which
moves the existing VM to a different host and keeps its disk, so it tests placement cheaply.
`Recreate` deletes the VM and its OS disk and re-runs the deployment, which builds a new VM from
the image and re-applies the guest configuration. The NIC is left in place in both cases, so the
router keeps the static address the route tables point at.

The script exits with code 1 when an iteration falls below the threshold, when the path check
fails, or when a router change does not come back, so it can be dropped straight into a pipeline.

```
Iteration GbpsSent PercentOfBaseline Status     Detail
--------- -------- ----------------- ------     ------
        1     6.97            100.00 acceptable first hop 10.30.0.4, 4500 retransmits
        2     6.58             94.50 acceptable first hop 10.30.0.4, 20216 retransmits
```

A redeploy takes several minutes and a rebuild longer still, so budget roughly
`DurationSeconds + 5 minutes` per iteration. Forwarding survives both because it is persisted in
the guest: `IPEnableRouter` on Windows and the sysctl drop-in on Linux.

### Stopping a run with Ctrl+C

Press Ctrl+C to stop. The run does not die on the spot: it finishes the step it is on, then
prints its summary and writes the CSV, so a run interrupted half way still reports everything it
measured. This matters most during a deployment or a resize, where being killed outright leaves
half-built resources behind that the next run has to clean up.

Ctrl+C is treated as console input rather than as an interrupt signal, because
`Console.CancelKeyPress` does not reliably keep a PowerShell pipeline alive - the run gets torn
down anyway and the summary never prints. The keystroke is buffered, so pressing it during a long
`az` call registers as soon as that call returns; the scripts also check while polling for a VM to
come back, which is where most of the waiting happens. A cancelled run exits with code 130 rather
than 1, so a wrapper can tell an operator stopping the run apart from a throughput failure.

Under the fleet the same keystroke stops every instance, since they share the flag. Resource
groups are left in place unless `-DeleteResourceGroupsOnExit` was passed.

### Fleet test across many deployments

`test-fleet.ps1` scales the same idea out. It creates N resource group names from a prefix -
`<prefix>-01`, `<prefix>-02`, and so on - and starts one `test-redeploy-loop.ps1` per resource
group. All the deploy, resize, recreate and connectivity logic lives in that script; the fleet
script only launches instances and monitors them. The whole run stops the moment any single
instance fails.

Instances do not wait for each other at any point. A slow deployment in one resource group does
not hold up testing in another, and an instance that is mid-rebuild does not stop its neighbours
from measuring. The only thing shared between them is an abort flag: the first worker to fail
sets it and the others stop at their next stage boundary, so a failure is not masked by the rest
of the fleet continuing to run.

```powershell
.\test-fleet.ps1 -ResourceGroupPrefix sabansal-fwd -Location westus2 -InstanceCount 4
```

| Switch | Purpose |
| --- | --- |
| `-InstanceCount <n>` | How many independent copies of the topology to run. Defaults to 3. |
| `-RouterChange <mode>` | What happens to each router between iterations: `Recreate` (default here), `Redeploy`, or `None`. |
| `-IterationsBeforeChange <m>` | Successful iterations between router VM changes. Defaults to 3. |
| `-InitialRouterVmSize <sku>` | Create the routers on this SKU, on the initial deploy and on every rebuild. |
| `-ResizedRouterVmSize <sku>` | Resize a router to this SKU as soon as it is created, before anything is measured. |
| `-RouterTimeoutMinutes <n>` | How long to wait for a router after a resize or rebuild. Defaults to 20. |
| `-MaxIterations <n>` | Stop after this many iterations. Defaults to 0, meaning run until a failure. |
| `-ThresholdPercent <n>` | Acceptance threshold against each instance's own baseline. Defaults to 80. |
| `-MinimumMbps <n>` | Absolute throughput floor in Mbits/sec applied to every instance. Defaults to 100. Set to 0 to disable. |
| `-SummaryEveryIterations <n>` | How often each instance prints a progress summary and flushes its results. Defaults to 10. |
| `-BaselineGbps <n>` | Use one fixed baseline for every instance instead of measuring one per instance. |
| `-SkipDeploy` | Reuse resource groups that are already deployed. |
| `-MaxParallel <n>` | Limit how many instances are worked on at once. Defaults to all of them. |
| `-DeleteResourceGroupsOnExit` | Delete the resource groups when the run ends. |
| `-LogDirectory <path>` | Where per-instance logs go. Defaults to a timestamped folder next to the script. |

Each instance measures its own baseline on its first iteration, because throughput depends on
the hosts a given deployment happened to land on. Comparing every instance against a single
shared number would produce false failures. Instances also run their iterations independently,
so they drift out of step with each other: one may be on iteration 5 while another is still
rebuilding its router after iteration 3.

Because workers run concurrently, the console shows one short milestone line per instance,
prefixed with the resource group, and these interleave:

```
[sabansal-fwd-01] deployed in 207 seconds
[sabansal-fwd-02] deploying...
[sabansal-fwd-01] resizing the router to Standard_D4s_v6...
[sabansal-fwd-01] iteration 1 baseline 11.13 Gbits/sec, first hop 10.30.0.4
[sabansal-fwd-03] FAILED - 4.10 Gbits/sec on iteration 2 is 58.4% of the 7.02 Gbits/sec baseline
```

Each instance writes its full output, including everything the deployment and the connectivity
test printed, to `<LogDirectory>\<resource-group>.log`, and the run writes a `summary.csv` with
the per-instance outcome. The script exits with code 1 when any instance fails.

Note the difference between the two loops. `test-redeploy-loop.ps1` uses `az vm redeploy`, which
moves the existing VM to a different host and keeps its disk. `test-fleet.ps1` deletes the VM and
its OS disk and builds a new one from the image, which also re-runs the guest configuration. The
NIC is deliberately left in place in both cases so the router keeps the static address the route
tables point at.

### Changing the router SKU between runs

To exercise a create-on-one-size then move-to-another cycle, deploy the routers on one SKU and
have them resized to another before anything is measured:

```powershell
.\test-fleet.ps1 -ResourceGroupPrefix sabansal-fwd -Location westus2 -InstanceCount 2 `
  -InitialRouterVmSize Standard_D2s_v6 -ResizedRouterVmSize Standard_D4s_v6
```

Every time a router VM comes into existence it is created on `-InitialRouterVmSize` and
immediately resized to `-ResizedRouterVmSize`, before the next iteration runs. That applies to
the initial deployment and to every later rebuild, so a rebuild repeats the whole cycle instead
of jumping straight to the target size. Every measurement is therefore taken on the target size,
and the baselines stay comparable across rebuilds.

Both sizes are validated against the region before anything is deployed, so a typo fails in
seconds rather than after N deployments.

A resize is not done in place. A target size is generally not offered by the cluster the VM
currently sits on, so `resize-router.ps1` deallocates the VM, resizes it, and starts it again,
which also lands it on a new host. Forwarding survives because it is persisted on the OS disk and
re-applied at boot, and the NIC keeps the static address. Resizing to the size the VM already
runs is a no-op, so the resize phase is safe to repeat and safe to use with `-SkipDeploy`.

Every VM in this topology boots from the NVMe disk controller, set on the OS disk at deployment
time. That is the reason all the sizes used here are v6 or newer: v6 and v7 sizes boot from NVMe
only, while Dv2, Dv4 and Dv5 boot from SCSI only. Pinning one controller keeps a resize to a plain
size change, because the controller never has to move with it. Mixing families does not work: a
resize from a Dv4 or Dv5 size to a v6 or v7 size fails with `cannot boot with DiskControllerType`,
and forcing the controller across at the same time leaves a VM that will not start. Both images
this topology uses report `SCSI, NVMe`, so NVMe boots on Linux and on Windows. If a size that
cannot boot from NVMe is passed, the resize says so and restarts the VM at its original size.

The VMs carry no data disks; each has only its OS disk.

The single-resource-group loop takes the same pair of switches, where the size cycle replaces the
redeploy for every iteration:

```powershell
.\test-redeploy-loop.ps1 -ResourceGroupName <resource-group> `
  -InitialRouterVmSize Standard_D2s_v6 -ResizedRouterVmSize Standard_D4s_v6
```

`deploy.ps1` takes them too, so a one-off deployment can go through the same cycle:

```powershell
.\deploy.ps1 -ResourceGroupName <resource-group> -Location <location> `
  -RouterVmSize Standard_D2s_v6 -ResizedRouterVmSize Standard_D4s_v6 -RunConnectivityTest
```

`resize-router.ps1` can also be used on its own against a deployed topology:

```powershell
.\resize-router.ps1 -ResourceGroupName <resource-group> -VmSize Standard_D4s_v6
```

### Manual checks

SSH to endpoint A using its public IP, then confirm the path goes through the router:

```bash
traceroute -n <endpoint-b-private-ip>
```

The first hop must be `10.30.0.4`.

Run a throughput test across the router. On endpoint B:

```bash
iperf3 -s -p 5001
```

On endpoint A:

```bash
iperf3 -c <endpoint-b-private-ip> -p 5001
```

Watch the traffic transit the router. On a Linux router:

```bash
sudo tcpdump -ni eth0 host <endpoint-a-private-ip> and host <endpoint-b-private-ip>
```

Confirm forwarding state on a Linux router:

```bash
sysctl net.ipv4.ip_forward
```

Confirm forwarding state on a Windows router:

```powershell
Get-NetIPInterface -AddressFamily IPv4 | Select-Object InterfaceAlias, Forwarding
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name IPEnableRouter
```

## Troubleshooting

### TCP never establishes and the router sees a single SYN with no retransmits

That signature means the router received the SYN, refused to forward it, and answered with an
ICMP administratively-prohibited message, so the client gave up instead of retransmitting. It
is a guest firewall problem, not an Azure routing problem — if Azure routing were wrong, no
SYN would reach the router at all.

The usual cause is `firewalld`. When `firewalld` is running it installs its rules into its own
`inet firewalld` nftables table and rejects forwarded traffic inside a zone by default. A plain
`iptables -I FORWARD 1 -j ACCEPT` writes to a *different* table and therefore does not override
it. Forwarding has to be allowed through `firewalld` itself:

```bash
sudo firewall-cmd --permanent --add-forward
sudo firewall-cmd --permanent --direct --add-rule ipv4 filter FORWARD 0 -j ACCEPT
sudo firewall-cmd --reload
```

Inspect the live router, or inspect and repair it in place, with:

```powershell
.\diagnose.ps1 -ResourceGroupName <resource-group> -RouterVmName <router-vm>
.\diagnose.ps1 -ResourceGroupName <resource-group> -RouterVmName <router-vm> -Repair
```

Redeploying with `deploy.ps1` also applies the fix, because the run command re-executes when
its script changes.

### Checklist for other failure modes

| Symptom | Check |
| --- | --- |
| No SYN reaches the router at all | Effective routes on the endpoint NIC: `az network nic show-effective-route-table`. The `10.30.x.0/24` route must show next hop `10.30.0.4`. |
| SYN reaches the router and is forwarded, but nothing comes back | The *other* endpoint's route table, and `enableIPForwarding` on the router NIC. Azure drops transit packets when that flag is off. |
| Traffic works but bypasses the router after the first packet | ICMP redirects. The router must have `send_redirects=0` and the endpoints `accept_redirects=0`. These are per-interface settings, so the `all` and `default` sysctl keys alone are not enough. |
| Connection refused immediately from the far endpoint | Nothing is listening, or the guest firewall on the destination blocks the port. The deployment opens `5000-6000` only. |
| Windows router: `Set-NetIPInterface : No matching MSFT_NetIPInterface objects found` | Accelerated Networking exposes both the synthetic NetVSC NIC and the Mellanox virtual function as physical adapters that are `Up`. The VF has no IPv4 stack, so setting forwarding by adapter index fails. Enumerate `Get-NetIPInterface -AddressFamily IPv4` instead of `Get-NetAdapter -Physical`. |
| A script run through `az vm run-command invoke` only executes its first line | A multi-line string passed to `--scripts` is split into separate arguments, so the remaining lines are consumed as if they were CLI arguments and `--query` is swallowed. Write the script to a file and pass `--scripts "@<file>"`, which is what these scripts do. |
| A `run-command` script returns truncated output | Azure keeps only the last few kilobytes of stdout. Do the parsing on the VM and return a small summary, as `test-connectivity.ps1` does with the iperf3 JSON report. |
| `tcpdump` on the router captures nothing while traffic is clearly flowing | Accelerated Networking moves the traffic onto the Mellanox virtual function, which a capture on the synthetic interface or on `any` does not see. Use the kernel counters instead: `grep '^Ip:' /proc/net/snmp` and watch `ForwDatagrams`. |
| The Linux router deployment fails with "a reject or drop rule remains in a forward chain" | A firewalld zone always keeps a trailing `reject with icmpx admin-prohibited` in `filter_FORWARD` that cannot be removed while firewalld runs. It is unreachable once the zone target is `ACCEPT`, because firewalld then puts a catch-all `accept` in `filter_FORWARD_POLICIES`, which is jumped to first. Verify the zone target and that catch-all rather than grepping the ruleset for the words reject or drop, which also matches legitimate rules such as `ct state invalid drop`. |

## Notes and constraints

- `routerPrivateIpAddress` is statically assigned so that the route tables can be created
  before the router VM exists. Change it together with `routerSubnetPrefix`, and keep it
  outside the first four addresses of the subnet, which Azure reserves.
- `routerVmSize` must support Accelerated Networking and must boot from NVMe, so it has to be a v6 size or newer. The default `Standard_D4s_v6` does both.
- The Linux router disables ICMP redirects and the endpoints ignore them, so traffic keeps
  traversing the router even though it forwards packets back out of the interface they
  arrived on.
- The Windows router does not install the RemoteAccess or Routing (RRAS) roles. RRAS is only
  needed for NAT, demand-dial, VPN, or dynamic routing protocols. Static forwarding between
  subnets is performed by the TCP/IP stack itself, so the roles would add several minutes and
  a reboot to the deployment without changing the datapath. `Set-NetIPInterface -Forwarding
  Enabled` takes effect immediately; the `IPEnableRouter` registry value makes it survive a
  restart.
- With Accelerated Networking, forwarded flows are handled by the guest rather than offloaded
  to the NIC, so router throughput is bounded by the VM's CPU.
- The Windows router VM does not get `iperf3` or `tcpdump`. Use `pktmon` or `netsh trace`
  there instead.
