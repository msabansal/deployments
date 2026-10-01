targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Prefix applied to every resource name.')
param namePrefix string = 'sabansal-wireguard'

@description('Administrator user name for both VMs.')
param adminUsername string = 'azureuser'

@description('SSH public key used by both VMs.')
@secure()
param adminPublicKey string

@description('VM size. Standard_D2als_v7 requires an NVMe disk controller.')
param vmSize string = 'Standard_D2als_v7'

@description('Address space of the virtual network.')
param vnetAddressPrefix string = '10.70.0.0/16'

@description('Address prefix of the VM subnet.')
param subnetAddressPrefix string = '10.70.0.0/24'

@description('Private IP of the WireGuard server VM.')
param serverPrivateIp string = '10.70.0.4'

@description('Private IP of the WireGuard client VM.')
param clientPrivateIp string = '10.70.0.5'

var serverVmName = '${namePrefix}-server'
var clientVmName = '${namePrefix}-client'

var installToolsScript = '''
#!/bin/bash
set -euo pipefail

if command -v tdnf >/dev/null 2>&1; then
  tdnf install -y wireguard-tools iproute iputils ethtool curl tar gcc make autoconf automake libtool openssl-devel
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y wireguard-tools iproute iputils ethtool curl tar gcc make autoconf automake libtool openssl-devel
else
  echo "No supported package manager found" >&2
  exit 1
fi

iperf_version=3.22
iperf_archive="iperf-$iperf_version.tar.gz"
iperf_sha256=1c0d0fb02c52626111d6e132db80edfbf27bbaff8bd9245df2a371dcb0b35a92
iperf_gro_cpu_fix=ee73f1740f689cafde3cde13d711eecbac985090
iperf_marker=/usr/local/share/iperf3-gsro-cpu-fix
if ! /usr/local/bin/iperf3 --help 2>&1 | grep -q -- '--gsro' \
    || ! grep -qx "$iperf_gro_cpu_fix" "$iperf_marker" 2>/dev/null; then
  build_dir=$(mktemp -d)
  trap 'rm -rf "$build_dir"' EXIT
  cd "$build_dir"
  curl -fsSLO "https://github.com/esnet/iperf/releases/download/$iperf_version/$iperf_archive"
  echo "$iperf_sha256  $iperf_archive" | sha256sum -c -
  tar -xzf "$iperf_archive"
  cd "iperf-$iperf_version"
  grep -q 'ret = recvmsg(fd, &msg, MSG_DONTWAIT);' src/net.c
  sed -i '/ret = recvmsg(fd, &msg, MSG_DONTWAIT);/s/MSG_DONTWAIT/0/' src/net.c
  grep -q 'ret = recvmsg(fd, &msg, 0);' src/net.c
  ./configure --prefix=/usr/local
  make -j"$(nproc)"
  make install
  ldconfig
  install -d /usr/local/share
  echo "$iperf_gro_cpu_fix" >"$iperf_marker"
fi
/usr/local/bin/iperf3 --help 2>&1 | grep -q -- '--gsro'

cat >/etc/sysctl.d/90-wireguard-throughput.conf <<EOF
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.netdev_max_backlog = 250000
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
EOF
sysctl --system >/dev/null

ethtool -K eth0 gro on gso on tso on 2>/dev/null || true
ethtool -K eth0 rx-udp-gro-forwarding on 2>/dev/null || true

install -d -m 700 /etc/wireguard
if [ ! -s /etc/wireguard/privatekey ]; then
  umask 077
  wg genkey >/etc/wireguard/privatekey
  wg pubkey </etc/wireguard/privatekey >/etc/wireguard/publickey
fi

if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port=51820/udp
  firewall-cmd --permanent --add-port=5201/tcp
  firewall-cmd --permanent --add-port=5201/udp
  firewall-cmd --reload
fi

echo "WireGuard and GSO-enabled iperf3 installed"
'''

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${namePrefix}-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowCorpnetPublicInbound'
        properties: {
          access: 'Allow'
          direction: 'Inbound'
          priority: 100
          protocol: '*'
          sourceAddressPrefix: 'CorpnetPublic'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'AllowCorpnetSAWInbound'
        properties: {
          access: 'Allow'
          direction: 'Inbound'
          priority: 110
          protocol: '*'
          sourceAddressPrefix: 'CorpnetSAW'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'AllowVirtualNetworkInbound'
        properties: {
          access: 'Allow'
          direction: 'Inbound'
          priority: 120
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'DenyAllOtherInbound'
        properties: {
          access: 'Deny'
          direction: 'Inbound'
          priority: 4096
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: '${namePrefix}-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: 'wireguard'
        properties: {
          addressPrefix: subnetAddressPrefix
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

resource serverPublicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: '${serverVmName}-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource clientPublicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: '${clientVmName}-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource serverNic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${serverVmName}-nic'
  location: location
  properties: {
    enableAcceleratedNetworking: true
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: serverPrivateIp
          publicIPAddress: {
            id: serverPublicIp.id
          }
          subnet: {
            id: vnet.properties.subnets[0].id
          }
        }
      }
    ]
  }
}

resource clientNic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${clientVmName}-nic'
  location: location
  properties: {
    enableAcceleratedNetworking: true
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: clientPrivateIp
          publicIPAddress: {
            id: clientPublicIp.id
          }
          subnet: {
            id: vnet.properties.subnets[0].id
          }
        }
      }
    ]
  }
}

resource serverVm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: serverVmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: serverNic.id
          properties: {
            primary: true
          }
        }
      ]
    }
    osProfile: {
      computerName: serverVmName
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        provisionVMAgent: true
        ssh: {
          publicKeys: [
            {
              keyData: adminPublicKey
              path: '/home/${adminUsername}/.ssh/authorized_keys'
            }
          ]
        }
      }
    }
    storageProfile: {
      diskControllerType: 'NVMe'
      imageReference: {
        publisher: 'MicrosoftAzureLinux'
        offer: 'azurelinux-4'
        sku: '4'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

resource clientVm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: clientVmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: clientNic.id
          properties: {
            primary: true
          }
        }
      ]
    }
    osProfile: {
      computerName: clientVmName
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        provisionVMAgent: true
        ssh: {
          publicKeys: [
            {
              keyData: adminPublicKey
              path: '/home/${adminUsername}/.ssh/authorized_keys'
            }
          ]
        }
      }
    }
    storageProfile: {
      diskControllerType: 'NVMe'
      imageReference: {
        publisher: 'MicrosoftAzureLinux'
        offer: 'azurelinux-4'
        sku: '4'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

resource installServerTools 'Microsoft.Compute/virtualMachines/runCommands@2024-07-01' = {
  name: 'install-wireguard'
  parent: serverVm
  location: location
  properties: {
    treatFailureAsDeploymentFailure: true
    source: {
      script: replace(installToolsScript, '\r', '')
    }
  }
}

resource installClientTools 'Microsoft.Compute/virtualMachines/runCommands@2024-07-01' = {
  name: 'install-wireguard'
  parent: clientVm
  location: location
  properties: {
    treatFailureAsDeploymentFailure: true
    source: {
      script: replace(installToolsScript, '\r', '')
    }
  }
}

output serverVmName string = serverVm.name
output clientVmName string = clientVm.name
output serverPrivateIp string = serverPrivateIp
output clientPrivateIp string = clientPrivateIp
output serverPublicIp string = serverPublicIp.properties.ipAddress
output clientPublicIp string = clientPublicIp.properties.ipAddress
output serverTunnelIp string = '10.200.0.1'
output clientTunnelIp string = '10.200.0.2'
