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
.\deploy.ps1 -ResourceGroupName <resource-group> -Location <location> -RouterVmSize Standard_DS2_v2
```

The size must support Accelerated Networking. Note that `Standard_D2s_v2` does not exist: the
two-vCPU premium-storage Dv2 SKU is `Standard_DS2_v2`.

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

### Continuous redeploy test

`test-redeploy-loop.ps1` answers a different question: does forwarding still perform after the
router lands on a different host? Each iteration runs the throughput test and compares it with
a baseline. While the result stays at or above 80 percent of the baseline the router VM is
redeployed onto a new host and the test runs again. The loop stops on the first iteration that
falls short, which is the placement worth investigating.

```powershell
.\test-redeploy-loop.ps1 -ResourceGroupName <resource-group>
```

| Switch | Purpose |
| --- | --- |
| `-BaselineGbps <n>` | Compare against a known figure instead of measuring one on the first iteration. |
| `-ThresholdPercent <n>` | Acceptance threshold. Defaults to 80. |
| `-MaxIterations <n>` | Stop after this many iterations. Defaults to 0, meaning run until a failure. |
| `-RedeployTimeoutMinutes <n>` | How long to wait for the router VM after a redeploy. Defaults to 20. |
| `-ResizedRouterVmSize <sku>` | Move the router to this SKU before every run. With `-InitialRouterVmSize` this replaces the redeploy with a full size cycle. |
| `-InitialRouterVmSize <sku>` | The SKU the router is put back on at the start of each cycle. |
| `-ResultCsvPath <path>` | Write the per-iteration results to CSV. |

The script exits with code 1 when an iteration falls below the threshold, when the path check
fails, or when a redeploy does not come back, so it can be dropped straight into a pipeline.

```
Iteration GbpsSent PercentOfBaseline Status     Detail
--------- -------- ----------------- ------     ------
        1     6.97            100.00 acceptable first hop 10.30.0.4, 4500 retransmits
        2     6.58             94.50 acceptable first hop 10.30.0.4, 20216 retransmits
```

A redeploy takes several minutes, so budget roughly `DurationSeconds + 5 minutes` per
iteration. Forwarding survives a redeploy because it is persisted in the guest: `IPEnableRouter`
on Windows and the sysctl drop-in on Linux.

### Fleet test across many deployments

`test-fleet.ps1` scales the same idea out. It creates N resource groups named `<prefix>-01`,
`<prefix>-02`, and so on, deploys the topology into each of them, and then runs the connectivity
test in all of them at the same time. Every N successful iterations the router VM is deleted
outright, along with its OS disk, and recreated by re-running the deployment. The whole run
stops the moment any single instance fails.

```powershell
.\test-fleet.ps1 -ResourceGroupPrefix sabansal-fwd -Location westus2 -InstanceCount 4
```

| Switch | Purpose |
| --- | --- |
| `-InstanceCount <n>` | How many independent copies of the topology to run. Defaults to 3. |
| `-IterationsBeforeRecreate <m>` | Successful iterations between router VM rebuilds. Defaults to 3. |
| `-InitialRouterVmSize <sku>` | Create the routers on this SKU, on the initial deploy and on every rebuild. |
| `-ResizedRouterVmSize <sku>` | Resize a router to this SKU as soon as it is created, before anything is measured. |
| `-ResizeTimeoutMinutes <n>` | How long to wait for a router after the resize. Defaults to 20. |
| `-MaxIterations <n>` | Stop after this many iterations. Defaults to 0, meaning run until a failure. |
| `-ThresholdPercent <n>` | Acceptance threshold against each instance's own baseline. Defaults to 80. |
| `-BaselineGbps <n>` | Use one fixed baseline for every instance instead of measuring one per instance. |
| `-SkipDeploy` | Reuse resource groups that are already deployed. |
| `-MaxParallel <n>` | Limit how many instances are worked on at once. Defaults to all of them. |
| `-DeleteResourceGroupsOnExit` | Delete the resource groups when the run ends. |
| `-LogDirectory <path>` | Where per-instance logs go. Defaults to a timestamped folder next to the script. |

Each instance measures its own baseline on its first iteration, because throughput depends on
the hosts a given deployment happened to land on. Comparing every instance against a single
shared number would produce false failures.

```
  sabansal-fwd-01      7.02 Gbits/sec   100.0% of baseline
  sabansal-fwd-02      6.71 Gbits/sec    95.6% of baseline
  sabansal-fwd-03  FAILED  4.10 Gbits/sec is 58.4% of the 7.02 Gbits/sec baseline
```

Instances run in parallel runspaces, so their console output would otherwise interleave. Each
instance writes its full output to `<LogDirectory>\<resource-group>-<phase>.log`, and the run
writes a `summary.csv` with the per-instance outcome. The script exits with code 1 when any
instance fails.

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
  -InitialRouterVmSize Standard_DS2_v2 -ResizedRouterVmSize Standard_D2s_v5
```

Every time a router VM comes into existence it is created on `-InitialRouterVmSize` and
immediately resized to `-ResizedRouterVmSize`, before the next iteration runs. That applies to
the initial deployment and to every later rebuild, so a rebuild repeats the whole cycle instead
of jumping straight to the target size. Every measurement is therefore taken on the target size,
and the baselines stay comparable across rebuilds.

Both sizes are validated against the region before anything is deployed, so a typo fails in
seconds rather than after N deployments. `Standard_D2s_v2` is a common one: it does not exist,
and the size intended is almost always `Standard_DS2_v2`.

A resize is not done in place. The Dv2 family runs on Haswell and Broadwell hosts and the Dv5
family runs on Ice Lake hosts, so the target size is not offered by the cluster the VM currently
sits on. `resize-router.ps1` therefore deallocates the VM, resizes it, and starts it again, which
also lands it on a new host. Forwarding survives because it is persisted on the OS disk and
re-applied at boot, and the NIC keeps the static address. Resizing to the size the VM already
runs is a no-op, so the resize phase is safe to repeat and safe to use with `-SkipDeploy`.

The single-resource-group loop takes the same pair of switches, where the size cycle replaces the
redeploy for every iteration:

```powershell
.\test-redeploy-loop.ps1 -ResourceGroupName <resource-group> `
  -InitialRouterVmSize Standard_DS2_v2 -ResizedRouterVmSize Standard_D2s_v5
```

`deploy.ps1` takes them too, so a one-off deployment can go through the same cycle:

```powershell
.\deploy.ps1 -ResourceGroupName <resource-group> -Location <location> `
  -RouterVmSize Standard_DS2_v2 -ResizedRouterVmSize Standard_D2s_v5 -RunConnectivityTest
```

`resize-router.ps1` can also be used on its own against a deployed topology:

```powershell
.\resize-router.ps1 -ResourceGroupName <resource-group> -VmSize Standard_D2s_v5
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
- `routerVmSize` must support Accelerated Networking. The default `Standard_D4s_v5` does.
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
