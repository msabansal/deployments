# VM with Bing-only DNS resolver policy

One Azure Linux 4 VM and an Azure DNS Private Resolver inbound endpoint in a
single VNet. The VM's NIC uses the inbound endpoint as its DNS server. A native
Azure DNS resolver policy is linked to the VNet, not directly to the resolver.
There is no outbound endpoint or forwarding ruleset: public DNS uses Azure's
recursive resolution.

```text
VM (10.50.0.0/24) -- DNS --> Resolver inbound (10.50.1.4, dedicated /28)
                                |
                     VNet-linked resolver policy
                     100: Allow www.bing.com
                     200: Block . (all other domains)
```

## Policy behavior and limitations

The only entry in the allow list is `www.bing.com`; `bing.com`, other Bing
hosts, and unrelated domains are not explicitly allowed. Both rules are enabled.
Lower priority numbers win.

This uses the native Azure matching semantics selected for this topology:
domain rules also match descendants, and Azure examines CNAME chains. This is
**not a strict exact-query-name filter**. Descendants of `www.bing.com` and
names whose CNAME chains match the allow rule can also be allowed. CNAME
handling can affect whether a live Bing response resolves successfully; the
post-deployment probe verifies the actual response without expanding the allow list.
See [DNS resolver policy](https://learn.microsoft.com/azure/dns/dns-security-policy).

The VM subnet NSG permits TCP/UDP port 53 to the inbound endpoint and denies
port 53 to other servers. Azure platform DNS is exempt from ordinary NSG rules
and remains reachable without an explicit `AzurePlatformDNS` deny rule.
The resolver policy applies to both DNS paths.
This is DNS filtering, **not internet egress isolation**:
DNS-over-HTTPS, DNS-over-TLS, and connections to literal IP addresses are not blocked.

Blocking other names can break package installation, VM extensions, Azure
agent services, and web content that uses other hosts. SSH uses the public IP
so it does not depend on the VM resolving an SSH host name. Only SSH from
`CorpnetPublic` and `CorpnetSAW` is permitted inbound, following the other
Azure Linux topology's access convention.

## Deploy

Prerequisites: PowerShell 7+, Azure CLI with Bicep, `az login`, the desired
subscription selected, and an existing SSH public key. Choose a region that
supports DNS Private Resolver, DNS resolver policies, and the Azure Linux image.
The resolver endpoint, policy, and VM incur Azure charges.

```powershell
.\deploy.ps1 -ResourceGroupName rg-vm-dns-bing-only -Location centralindia `
  -SshPublicKeyPath '~\.ssh\id_ed25519.pub'
```

The wrapper creates the resource group and deploys the topology. It prints VM,
resolver, and policy IDs, the resolver IP, the public IP, and an SSH command.
It does not install packages after applying the restrictive DNS policy.

Edit `main.bicepparam` for network ranges, username, or image version.
If changing the resolver subnet, also change `resolverIpAddress` to a usable
address in that subnet. Its first four addresses and last address are reserved.
The resolver subnet must be dedicated and between `/28` and `/24`.
`-VmName`, `-VmSize`, and `-DiskControllerType` override their defaults. The VM
size must support the selected controller and Accelerated Networking (default
`Standard_D2als_v6`, 2 vCPUs, 4 GiB, NVMe). When using a SCSI-only size, also
pass `-DiskControllerType SCSI`.
The OS disk is Standard SSD and authentication is SSH-key only.

## Verify DNS after deployment

Run the standard-library-only Python probe from the VM over SSH (Python 3
must already be present on the image). Substitute the public IP from the outputs:

```powershell
Get-Content -Raw "$PSScriptRoot\test-dns.py" |
  ssh azureuser@<public-ip> 'python3 - --server 10.50.1.4 --server 168.63.129.16'
if ($LASTEXITCODE -ne 0) { throw 'DNS policy verification failed.' }
```

From an interactive shell in this topology folder, use `.\test-dns.py` instead
of `$PSScriptRoot\test-dns.py`. The probe sends absolute A queries directly
over UDP to both DNS paths, bypassing local search suffixes and caches.
It requires an IPv4 answer for `www.bing.com` and the documented policy block
CNAME `blockpolicy.azuredns.invalid` for `bing.com`, `www.google.com`, and
`www.microsoft.com`. Timeouts, malformed replies, ordinary NXDOMAIN responses,
and missing allowed answers fail rather than masquerading as policy success.

## Local checks

```powershell
az bicep build --file .\main.bicep --stdout > $null
az bicep build-params --file .\main.bicepparam --stdout > $null
python -B .\test-dns-unit.py
```

For Azure-side preflight, use `az deployment group what-if` with the template,
parameter file, region, and SSH public key. A successful compile alone does not
verify regional availability or live DNS behavior.
