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
