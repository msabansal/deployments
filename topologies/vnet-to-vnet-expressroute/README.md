# VNet-to-VNet ExpressRoute deployment

This Bicep deployment implements the topology from the Azure Wiki page:

- simulated on-premises VNet with an ExpressRoute gateway
- Azure VNet with an ExpressRoute gateway
- ExpressRoute circuit using provider `bvtazureixp03`
- peering location `Noida2`
- Premium metered-data circuit SKU
- Azure private peering
- one connection from each VNet gateway to the circuit
- optional latest Azure Linux 3 test VM in each VNet
- Standard public IP on each optional test VM
- workload-subnet NSGs allowing `CorpnetPublic`, `CorpnetSAW`, and VNet traffic while denying all other inbound access

The defaults use zone-redundant `ErGw1AZ` ExpressRoute gateways and enable FastPath.

## Files

- `main.bicep` - deployment entry point and gateway connections
- `modules/vnet-with-expressroute-gateway.bicep` - VNet, subnets, public IP, and gateway
- `modules/expressroute-circuit.bicep` - circuit and optional Azure private peering
- `modules/test-vm.bicep` - private connectivity-test VM using the Azure Linux OS
- `main.bicepparam` - editable deployment values
- `deploy.ps1` - deployment wrapper that reads the SSH key from `~\.ssh\id_ed25519.pub` by default

## Deploy

Deploy without test VMs:

```powershell
.\deploy.ps1 -ResourceGroupName <resource-group> -Location <location>
```

To reuse existing VNets while still deploying their NSGs, ExpressRoute gateways, optional test VMs, and circuit connections:

```powershell
.\deploy.ps1 -ResourceGroupName <resource-group> -Location <location> -SkipVirtualNetworks
```

The equivalent Bicep parameter is `deployVirtualNetworks = false`.

The existing VNets must use the configured names and contain both a `workload` subnet and a `GatewaySubnet` with the address prefixes supplied in `main.bicepparam`.

To deploy only VM-related resources into existing VNets and skip all gateways, circuit, peering, and connections:

```powershell
.\deploy.ps1 -ResourceGroupName <resource-group> -Location <location> -VmsOnly
```

For other combinations, use `-SkipGatewaysAndCircuit`, `-SkipVirtualNetworks`, and `-DeployTestVms`. The equivalent Bicep control is `deployGatewaysAndCircuit`.

The deployment assumes that the BVT provider provisions the circuit automatically and therefore creates private peering and both gateway connections in the same deployment.

The `peerAsn`, `vlanId`, and `/30` peer prefixes are deployment-specific values. Confirm them before deploying.

## Optional test VMs

To deploy one Azure Linux 3 VM in each workload subnet, use:

```powershell
.\deploy.ps1 -ResourceGroupName <resource-group> -Location <location> -DeployTestVms
```

The script reads the administrator key from `~\.ssh\id_ed25519.pub`. Override it with `-SshPublicKeyPath <path>`.

The VMs use the latest `MicrosoftAzureLinux:azurelinux-4:4` image and have both private and Standard public IP addresses. Their workload-subnet NSGs allow inbound traffic from `CorpnetPublic`, `CorpnetSAW`, and the `VirtualNetwork` service tag, then deny all other inbound traffic. The deployment outputs both private and public IP addresses.

The VM uses the image's supported default security type rather than Trusted Launch.

Each VM runs the `install-network-tools` Custom Script extension after provisioning. It installs `tcpdump` and `iperf3` with the available `dnf` or `tdnf` package manager.
