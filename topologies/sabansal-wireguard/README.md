# Sabansal WireGuard

Deploys two Azure Linux 4 VMs in `westus3`, both using
`Standard_D2als_v7`, and creates a WireGuard tunnel between them:

```text
sabansal-wireguard-client                     sabansal-wireguard-server
10.70.0.5                                     10.70.0.4:51820
WireGuard 10.200.0.2  =====================>  WireGuard 10.200.0.1
```

The client connects to the server's private VNet address. TCP and UDP throughput
are measured with iperf3 against the server's WireGuard address, and the test
fails unless the route uses the `wg0` interface.

## Deploy and test

```powershell
.\deploy.ps1
```

Defaults:

- Resource group: `sabansal-wireguard-rg`
- Region: `westus3`
- VM size: `Standard_D2als_v7`
- Server private IP: `10.70.0.4`
- Client private IP: `10.70.0.5`
- Server tunnel IP: `10.200.0.1`
- Client tunnel IP: `10.200.0.2`

The deployment script creates the resource group, deploys both VMs, exchanges
their WireGuard public keys, configures the server and client, verifies the
tunnel, and runs 30-second TCP and UDP iperf3 tests. TCP uses four parallel
streams. UDP targets 2 Gbit/s and reports received throughput, packet loss, and
jitter.

Run the throughput test again with:

```powershell
.\test-throughput.ps1 `
  -ResourceGroupName sabansal-wireguard-rg `
  -ParallelConnections 4 `
  -UdpTargetMbps 2000 `
  -DurationSeconds 30
```

Benchmark the direct VNet path instead of the WireGuard tunnel:

```powershell
.\test-throughput.ps1 `
  -ResourceGroupName sabansal-wireguard-rg `
  -Path Direct `
  -ParallelConnections 4 `
  -UdpTargetMbps 2000 `
  -DurationSeconds 30
```

Direct mode targets `10.70.0.4` and fails if the selected route uses `wg0`.
