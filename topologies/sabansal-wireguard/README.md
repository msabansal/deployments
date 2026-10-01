# Sabansal WireGuard

Deploys two Azure Linux 4 VMs in `westus3`, both using
`Standard_D2als_v7`, and creates a WireGuard tunnel between them:

```text
sabansal-wireguard-client                     sabansal-wireguard-server
10.70.0.5                                     10.70.0.4:51820
WireGuard 10.200.0.2  =====================>  WireGuard 10.200.0.1
```

The client connects to the server's private VNet address. Throughput is measured
with iperf3 against the server's WireGuard address, and the test fails unless the
route uses the `wg0` interface.

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
tunnel, and runs a 30-second four-stream iperf3 test.

Run the throughput test again with:

```powershell
.\test-throughput.ps1 `
  -ResourceGroupName sabansal-wireguard-rg `
  -ParallelConnections 4 `
  -DurationSeconds 30
```
