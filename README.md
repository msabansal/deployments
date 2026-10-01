# Azure topology deployments

Infrastructure-as-code for repeatable Azure network topologies. Each topology is a
self-contained Bicep deployment with its own parameters, modules, and PowerShell
deployment wrapper, so it can be deployed independently of everything else here.

## Layout

```
topologies/
  <topology-name>/
    README.md            topology overview, parameters, and deploy instructions
    main.bicep           deployment entry point
    main.bicepparam      editable deployment values
    deploy.ps1           deployment wrapper (resolves paths from $PSScriptRoot)
    modules/             reusable Bicep modules for this topology
_template/               starting point for a new topology
```

## Topologies

| Topology | Description |
| --- | --- |
| [`azurelinux-vm`](topologies/azurelinux-vm/README.md) | One Azure Linux 4 VM on Ddv5 (4 vCPUs), with a Standard SSD OS disk, public IP, and subnet NSG allowing corpnet and SAW access. |
| [`vnet-to-vnet-expressroute`](topologies/vnet-to-vnet-expressroute/README.md) | Two VNets connected through an ExpressRoute circuit with zone-redundant gateways, private peering, and optional Azure Linux test VMs. |
| [`vm-ip-forwarding`](topologies/vm-ip-forwarding/README.md) | Two Linux VMs exchanging traffic through a third VM that forwards packets with OS routing. Router is Azure Linux 4 or Windows Server 2022, with Accelerated Networking. |
| [`sabansal-ilb-routing-two-infra`](topologies/sabansal-ilb-routing-two-infra/README.md) | Symmetric ILB routing through one secondary IP on infra VM 1; infra VM 2 has only its primary IP and is excluded from the backend pool. |

## Prerequisites

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) with the Bicep tooling (`az bicep install`)
- PowerShell 7+
- An authenticated session against the target subscription:

```powershell
az login
az account set --subscription <subscription-id>
```

## Deploying a topology

```powershell
cd topologies\<topology-name>
.\deploy.ps1 -ResourceGroupName <resource-group> -Location <location>
```

Each topology's `README.md` documents its own switches and parameters.

## Adding a new topology

1. Copy `_template` to `topologies\<topology-name>`.
2. Fill in `main.bicep`, `main.bicepparam`, and the topology `README.md`.
3. Validate before deploying:

```powershell
az bicep build --file topologies\<topology-name>\main.bicep --stdout > $null
az deployment group what-if `
  --resource-group <resource-group> `
  --template-file topologies\<topology-name>\main.bicep `
  --parameters topologies\<topology-name>\main.bicepparam
```

4. Add the topology to the table above.

## Conventions

- Keep every topology deployable on its own; do not share files across topology folders.
- Reference files from `deploy.ps1` with `$PSScriptRoot` so scripts work from any working directory.
- Never commit secrets. Pass SSH keys, passwords, and tokens at deploy time, or keep them
  in `*.local.bicepparam` files, which are ignored by git.
- Prefer parameters with sensible defaults over hard-coded values in modules.
