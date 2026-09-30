# Simple Azure Linux VM

Deploys one Azure Linux 4 VM using the latest published image, with a Standard SSD
OS disk, Accelerated Networking, and a Standard static public IPv4 address with a DNS label.
No extra software or VM extensions are installed.

The default size is `Standard_D4d_v5`: **4 vCPUs, 16 GiB RAM**, with a local
temporary disk. See the
[Ddv5 specifications](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/general-purpose/ddv5-series).
The VM uses a Generation 2 Azure Linux image and a SCSI disk controller.
This size does not support Premium storage; the OS disk defaults to `StandardSSD_LRS`.

## Network access

A VNet (`10.40.0.0/16`) contains one VM subnet (`10.40.0.0/24`).
The NSG is associated with the **subnet**; Azure does not attach NSGs directly to VNets.

| Priority | Source service tag | Inbound access |
| --- | --- | --- |
| 100 | `CorpnetPublic` | All ports and protocols |
| 110 | `CorpnetSAW` | All ports and protocols |
| 4096 | Any other source | Deny |

These source tags follow the existing topologies' corporate access convention.
They must be supported in the target Azure environment. There is no unrestricted
Internet or VNet inbound allow rule. Default NSG outbound rules remain unchanged.
The guest firewall and listening services still determine which ports respond.

SSH uses the VM's public DNS name or public IP and requires a connection whose source is covered by
`CorpnetPublic` or `CorpnetSAW`, plus the matching SSH private key. Password login
is disabled. This topology does not provision ExpressRoute, VPN, or corporate routing.

## Deploy

Use PowerShell 7+, Azure CLI with Bicep, and an authenticated target subscription:

```powershell
az login
az account set --subscription <subscription-id>

.\deploy.ps1 `
  -ResourceGroupName <resource-group> `
  -Location <region> `
  -SshPublicKeyPath ~\.ssh\id_ed25519.pub
```

Pass `-VmSize` to override the size in `main.bicepparam` for this deployment:

```powershell
.\deploy.ps1 -ResourceGroupName <resource-group> -Location <region> -VmSize Standard_D8d_v5
```

Omit `-VmSize` to keep the parameter file's value (`Standard_D4d_v5` by default).
The selected size must support the configured disk tier, disk controller, and
Accelerated Networking. When `-VmSize` is supplied, the wrapper queries the SKU in
the target region. If it supports only one disk controller type, the wrapper selects
that controller automatically. An incompatible explicit `-DiskControllerType` is
rejected before deployment. To use a Premium-storage-capable, NVMe-based size instead:

```powershell
.\deploy.ps1 -ResourceGroupName <resource-group> -Location <region> `
  -VmSize Standard_D4as_v7 -OsDiskStorageAccountType Premium_LRS -DiskControllerType NVMe
```

The public IP receives a stable, generated DNS label by default. To choose your own:

```powershell
.\deploy.ps1 -ResourceGroupName <resource-group> -Location <region> -PublicIpDnsLabel my-azlinux-vm
```

In Azure public cloud, this produces `my-azlinux-vm.<region>.cloudapp.azure.com`.
The label must be available in the region and contain 3-63 lowercase letters,
digits, or hyphens, starting with a letter and ending with a letter or digit.
Use the returned `publicIpFqdn` for the actual hostname. Redeploying an existing
topology applies the label to its public IP; no separate DNS zone is needed.

Choose a region with the selected VM size available, sufficient quota, and access
to `MicrosoftAzureLinux:azurelinux-4:4:latest`. Inspect SKU restrictions before deploying:

```powershell
az vm list-skus --location <region> --size Standard_D4d_v5 --all --output json
```

The wrapper creates the resource group if needed, then prints deployment outputs,
including `publicIpFqdn`, `sshCommand` (using the DNS name), public/private IP
addresses, and VM/VNet/NSG resource IDs.
Run the returned SSH command from corpnet or a SAW. If using a non-default private
key, add `-i <private-key-path>` to the command.

## Parameters

Edit `main.bicepparam` for non-secret deployment values:

| Parameter | Default | Purpose |
| --- | --- | --- |
| `namePrefix` | `azlinux` | Prefix for resource names |
| `vnetAddressPrefix` | `10.40.0.0/16` | VNet address space |
| `subnetAddressPrefix` | `10.40.0.0/24` | VM subnet within the VNet |
| `adminUsername` | `azureuser` | SSH administrator |
| `vmSize` | `Standard_D4d_v5` | 4 vCPUs and 16 GiB RAM; override with `-VmSize`; must support the disk settings and Accelerated Networking |
| `osDiskStorageAccountType` | `StandardSSD_LRS` | OS disk tier; override with `-OsDiskStorageAccountType`; Premium storage requires a compatible size |
| `diskControllerType` | `SCSI` | Disk controller; override with `-DiskControllerType`; must be supported by the size and image |
| `imageVersion` | `latest` | Azure Linux 4 image version; pin a version for repeatability |
| `publicIpDnsLabel` | `azlinux-<hash of resource group and namePrefix>` | Public IP DNS label; override with `-PublicIpDnsLabel` |
| `location` | Supplied by wrapper | Azure region |
| `adminPublicKey` | Supplied by wrapper | SSH public key read from `-SshPublicKeyPath` |

Do not deploy the parameter file's empty location/key placeholders directly.
Supply these values at deployment time; never commit private keys or credentials.
`latest` selects the image for VM creation; it does not automatically upgrade an
existing VM's guest OS.
