# Sabansal ECMP routing

Creates a separate Azure Linux 4 topology where VM1 and VM2 use an ECMP
user-defined route through both router VMs:

```text
VM1 10.81.1.4
      |
      | UDR: 10.81.2.0/24
      | nextHopType: VirtualApplianceEcmp
      v
      +--> router-1 primary IP 10.81.0.4
      |
      +--> router-2 primary IP 10.81.0.6
      |
      v
VM2 10.81.2.4
```

VM2 has the symmetric ECMP route for `10.81.1.0/24`. Azure hashes each flow
across the two equal-cost next hops. The Linux routers are stateless forwarding
appliances, so the forward and return directions can use different routers.

This topology has:

- no internal load balancer;
- no load-balancer frontend or backend pool;
- no shared or secondary router IP;
- only the router primary IPs `10.81.0.4` and `10.81.0.6`;
- Azure NIC IP forwarding and guest IPv4 forwarding on both routers.

All four VMs use Azure Linux 4 and default to `Standard_D2als_v6` with an NVMe
disk controller. The topology
uses the `2025-09-01` Network API because ECMP routes are represented as:

```bicep
properties: {
  addressPrefix: '10.81.2.0/24'
  nextHopType: 'VirtualApplianceEcmp'
  nextHop: {
    nextHopIpAddresses: [
      '10.81.0.4'
      '10.81.0.6'
    ]
  }
}
```

## Deploy into the existing resource group

The deployment creates uniquely named `sabansal-ecmp-routing-*` resources and
does not modify the existing ILB topology:

```powershell
.\deploy.ps1 `
  -ResourceGroupName sabansal-ilb-routing-rg `
  -Location centralindia `
  -UdpTargetMbps 5000 `
  -DurationSeconds 30
```

The validation uses direct SSH and checks:

- both configured routes contain exactly the two router primary IPs;
- VM1 and VM2 effective routes contain both router next-hop IPs (the effective
  route API currently reports the type as `VirtualAppliance`);
- VM1 can reach VM2 through the ECMP router tier;
- both routers forward benchmark traffic;
- received UDP throughput, packet loss, jitter, and VM1 CPU utilization.

Re-run only the benchmark with:

```powershell
.\test-throughput.ps1 `
  -ResourceGroupName sabansal-ilb-routing-rg `
  -UdpTargetMbps 5000 `
  -ParallelStreams 16 `
  -UdpDatagramBytes 1350 `
  -DurationSeconds 30
```

## Test results

See [Azure Linux networking test results](test-results.md) for the consolidated
direct, WireGuard, ILB, and ECMP benchmark and failover results.
