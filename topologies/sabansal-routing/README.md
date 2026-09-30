# Sabansal routing topology

Deploys three Azure Linux 4 VMs in one virtual network:

```text
sabansal-routing-vm1 (10.30.1.0/24)
              |
              | UDR: 10.30.2.0/24 via 10.30.0.4
              v
sabansal-routing-router (10.30.0.4)
              |
              | UDR: 10.30.1.0/24 via 10.30.0.4
              v
sabansal-routing-vm2 (10.30.2.0/24)
```

The endpoint subnets use user-defined routes to force traffic through the router VM.
The router NIC has Azure IP forwarding enabled, and the guest is configured with
Linux IP forwarding and firewall rules that allow transit traffic. The router does
not perform NAT, so VM2 observes VM1's private IP as the source address.

## Resources

- VNet: `sabansal-routing-vnet`
- Endpoint VMs: `sabansal-routing-vm1`, `sabansal-routing-vm2`
- Router VM: `sabansal-routing-router`
- Three subnets: `router`, `endpoint-a`, and `endpoint-b`
- Route tables on both endpoint subnets
- Public IPs for SSH management
- NSGs allowing corporate management access and VNet traffic

## Deploy

From this directory:

```powershell
.\deploy.ps1 `
  -ResourceGroupName sabansal-routing-rg `
  -Location centralindia
```

The script reads the SSH public key from `~\.ssh\id_ed25519.pub`. Override it or the
VM sizes when needed:

```powershell
.\deploy.ps1 `
  -ResourceGroupName sabansal-routing-rg `
  -Location centralindia `
  -SshPublicKeyPath ~\.ssh\id_ed25519.pub `
  -EndpointVmSize Standard_D2s_v5 `
  -RouterVmSize Standard_D2s_v5
```

## Verify routing

Run the connectivity and throughput test after deployment:

```powershell
.\test-connectivity.ps1 -ResourceGroupName sabansal-routing-rg
```

Or deploy and test in one command:

```powershell
.\deploy.ps1 `
  -ResourceGroupName sabansal-routing-rg `
  -Location centralindia `
  -RunConnectivityTest
```

The test verifies that:

- VM1's next hop toward VM2 is the router at `10.30.0.4`.
- VM2 observes VM1's original private IP, proving the router does not SNAT.
- The router's Linux forwarded-datagram counter increases during the test.
- `iperf3` traffic successfully travels from VM1 through the router to VM2.
