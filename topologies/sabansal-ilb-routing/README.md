# Sabansal ILB routing

Creates an Azure Linux 4 topology where VM1 and VM2 use an internal Standard
Load Balancer frontend as their symmetric routing next hop:

```text
VM1 10.80.1.4
      |
      | UDR: 10.80.2.0/24 via 10.80.0.10
      v
ILB frontend 10.80.0.10 (HA Ports, floating IP)
      |
      +--> router-1 secondary IP 10.80.0.5  [sole backend]
      |
      x--> router-2 primary IP 10.80.0.6    [not in backend pool]
      |
      v
VM2 10.80.2.4
```

The VM2 subnet has the reverse route for `10.80.1.0/24` through the same ILB
frontend. Router-1 has primary IP `10.80.0.4` and secondary IP `10.80.0.5`;
only the secondary IP is added to the IP-based backend pool. Router-2 exists as
the second router-tier VM but is deliberately excluded from the backend pool.

All four VMs use Azure Linux 4 and default to `Standard_D2als_v7`. Both router
NICs have Azure IP forwarding enabled, while the guest configuration enables
IPv4 forwarding, disables reverse-path filtering and redirects, and permits
forwarded traffic.

The backend remains IP-based during a router migration. Both router guests
configure `10.80.0.5/32` on `eth0`; they do not poll IMDS. Azure control-plane
ownership of the secondary NIC IP determines which router receives traffic for
that address. The backend address uses administrative state `Up` so that moving
`10.80.0.5` between NICs does not leave the unchanged backend suppressed while
the health-probe mapping converges. This override is appropriate here because
the pool intentionally contains exactly one controlled router IP.

To migrate the backend without recreating or changing the pool address:

```powershell
az feature register `
  --namespace Microsoft.Network `
  --name AllowMoveIpConfigurations

# Wait until the feature state is Registered, then refresh the provider.
az provider register --namespace Microsoft.Network

.\move-backend-ip.ps1 -DestinationRouter 2
```

The script uses the virtual network `moveIpConfigurations` REST action, which
moves the secondary IP configuration between NICs as one Azure control-plane
operation. This avoids the unassigned interval caused by separate NIC delete
and create requests. Use `-DestinationRouter 1` to move it back. The IP-based
backend pool and HA Ports rule remain unchanged.

## Deploy and test

```powershell
.\deploy.ps1 `
  -ResourceGroupName sabansal-ilb-routing-rg `
  -Location westus3 `
  -UdpTargetMbps 5000 `
  -DurationSeconds 30
```

The validation checks:

- the ILB backend pool contains only router-1's secondary IP;
- router-2 is not a backend;
- VM1 and VM2 effective routes use the ILB frontend IP;
- UDP traffic reaches VM2 through router-1;
- router-1's `ForwDatagrams` counter increases;
- router-2's forwarding counter remains unchanged;
- received throughput, packet loss, jitter, and VM1 CPU utilization.

Re-run only the benchmark with:

```powershell
.\test-throughput.ps1 `
  -ResourceGroupName sabansal-ilb-routing-rg `
  -UdpTargetMbps 5000 `
  -ParallelStreams 2 `
  -DurationSeconds 30
```
