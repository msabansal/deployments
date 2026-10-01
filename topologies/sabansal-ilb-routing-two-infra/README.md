# Sabansal ILB routing with two infra VMs

An independent deployment based on `sabansal-ilb-routing`. It has two endpoint
VMs and two infrastructure/router VMs, but only **one routing backend IP**:

| VM | NIC IPs | ILB backend |
| --- | --- | --- |
| router-1 (infra VM 1) | Primary `10.80.0.4`, secondary `10.80.0.5` | Secondary `10.80.0.5` only |
| router-2 (infra VM 2) | Primary `10.80.0.6` only | None |
| VM1 | `10.80.1.4` | None |
| VM2 | `10.80.2.4` | None |

VM1 and VM2 have symmetric UDRs pointing at ILB frontend `10.80.0.10`.
The internal Standard Load Balancer uses HA Ports with floating IP enabled and
an IP-based pool containing only `10.80.0.5`, with administrative state `Up`.
Only router-1 configures that routing IP in its guest. Router-2 enables forwarding
but neither owns nor configures the routing IP and receives no ILB-routed traffic.
This variant does not include the reference topology's backend-IP migration script.

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
not modified. Address ranges match the reference but belong to a separate,
unpeered VNet. The SSH public key defaults to `~\.ssh\id_ed25519.pub`.
Use `-SkipThroughputTest` to deploy without running the UDP benchmark.

## Validate and test

```powershell
.\test-throughput.ps1 `
  -ResourceGroupName sabansal-ilb-routing-two-infra-rg `
  -UdpTargetMbps 5000 `
  -ParallelStreams 2 `
  -DurationSeconds 30
```

The test verifies exactly two NIC IPs on router-1 and one on router-2, the sole
secondary-IP backend, and the effective routes on both endpoint NICs. It sends
UDP traffic from VM1 to VM2, verifies router-1's forwarding counter increases
while router-2's remains unchanged, and reports throughput, packet loss, jitter,
and VM1 CPU utilization.

An existing iperf3 listener is reused only if its process executable matches the
installed iperf3 binary. Otherwise a persistent server is started on VM2.
The test does not stop servers after completion or failure.
