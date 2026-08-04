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
    forwarding and the Routing role on Windows
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

The deployment outputs the private and public IP of every VM along with the configured test
port range.

## Verify forwarding

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

## Notes and constraints

- `routerPrivateIpAddress` is statically assigned so that the route tables can be created
  before the router VM exists. Change it together with `routerSubnetPrefix`, and keep it
  outside the first four addresses of the subnet, which Azure reserves.
- `routerVmSize` must support Accelerated Networking. The default `Standard_D4s_v5` does.
- The Linux router disables ICMP redirects and the endpoints ignore them, so traffic keeps
  traversing the router even though it forwards packets back out of the interface they
  arrived on.
- Installing the Windows Routing role can request a restart. When it does, the router VM
  reboots roughly two minutes after the deployment finishes.
- With Accelerated Networking, forwarded flows are handled by the guest rather than offloaded
  to the NIC, so router throughput is bounded by the VM's CPU.
- The Windows router VM does not get `iperf3` or `tcpdump`. Use `pktmon` or `netsh trace`
  there instead.
