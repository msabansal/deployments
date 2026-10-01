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
