@description('Azure region for all resources.')
param location string

@description('Name of the virtual machine.')
param vmName string

@description('Resource ID of the subnet.')
param subnetId string

@description('Administrator user name.')
param adminUsername string

@description('SSH public key used for the administrator account.')
@secure()
param adminPublicKey string

@description('Virtual machine size.')
param vmSize string = 'Standard_D2als_v6'

@description('Static primary private IP address.')
param primaryPrivateIpAddress string

@description('Enable Azure NIC IP forwarding and guest forwarding.')
param isRouter bool = false

var configureScript = '''
#!/bin/bash
set -euo pipefail

ROLE=__ROLE__

if command -v tdnf >/dev/null 2>&1; then
  PKG=tdnf
elif command -v dnf >/dev/null 2>&1; then
  PKG=dnf
else
  echo "No supported package manager found" >&2
  exit 1
fi

$PKG install -y iproute iputils ethtool curl tar gcc make autoconf automake libtool openssl-devel iptables tcpdump traceroute

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
  ./configure --prefix=/usr/local
  make -j"$(nproc)"
  make install
  ldconfig
  install -d /usr/local/share
  echo "$iperf_gro_cpu_fix" >"$iperf_marker"
fi
/usr/local/bin/iperf3 --help 2>&1 | grep -q -- '--gsro'

cat >/etc/sysctl.d/90-ecmp-routing.conf <<'SYSCTL'
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.netdev_max_backlog = 250000
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
SYSCTL

if [ "$ROLE" = "router" ]; then
  cat >>/etc/sysctl.d/90-ecmp-routing.conf <<'SYSCTL'
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
SYSCTL

  for interface_dir in /proc/sys/net/ipv4/conf/*/; do
    interface_name=$(basename "$interface_dir")
    case "$interface_name" in
      all|default) continue ;;
    esac
    echo "net.ipv4.conf.${interface_name}.rp_filter = 0" >>/etc/sysctl.d/90-ecmp-routing.conf
    echo "net.ipv4.conf.${interface_name}.send_redirects = 0" >>/etc/sysctl.d/90-ecmp-routing.conf
  done
fi

sysctl --system >/dev/null

ethtool -K eth0 gro on gso on tso on 2>/dev/null || true
ethtool -K eth0 rx-udp-gro-forwarding on 2>/dev/null || true

if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  ZONE=$(firewall-cmd --get-default-zone)
  firewall-cmd --permanent --zone="$ZONE" --add-port=5201/tcp
  firewall-cmd --permanent --zone="$ZONE" --add-port=5201/udp
  firewall-cmd --permanent --zone="$ZONE" --add-protocol=icmp || true
  if [ "$ROLE" = "router" ]; then
    firewall-cmd --permanent --zone="$ZONE" --set-target=ACCEPT
    firewall-cmd --permanent --zone="$ZONE" --add-forward || true
    firewall-cmd --permanent --direct --add-rule ipv4 filter FORWARD 0 -j ACCEPT || true
  fi
  firewall-cmd --reload
fi

if command -v iptables >/dev/null 2>&1; then
  iptables -C INPUT -p tcp --dport 5201 -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p tcp --dport 5201 -j ACCEPT
  iptables -C INPUT -p udp --dport 5201 -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p udp --dport 5201 -j ACCEPT
  if [ "$ROLE" = "router" ]; then
    iptables -P FORWARD ACCEPT || true
    iptables -C FORWARD -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -j ACCEPT
  fi
fi

if [ "$ROLE" = "router" ]; then
  test "$(cat /proc/sys/net/ipv4/ip_forward)" = "1"
fi

echo TOPOLOGY_VM_CONFIGURED
'''

var script = replace(configureScript, '__ROLE__', isRouter ? 'router' : 'endpoint')

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: '${vmName}-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource networkInterface 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${vmName}-nic'
  location: location
  properties: {
    enableAcceleratedNetworking: true
    enableIPForwarding: isRouter
    ipConfigurations: [
      {
        name: 'primary'
        properties: {
          primary: true
          privateIPAllocationMethod: 'Static'
          privateIPAddress: primaryPrivateIpAddress
          publicIPAddress: {
            id: publicIp.id
          }
          subnet: {
            id: subnetId
          }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: networkInterface.id
          properties: {
            primary: true
          }
        }
      ]
    }
    osProfile: {
      computerName: vmName
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
        diskSizeGB: 32
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
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

resource configure 'Microsoft.Compute/virtualMachines/runCommands@2024-07-01' = {
  name: 'configure-topology'
  parent: vm
  location: location
  properties: {
    treatFailureAsDeploymentFailure: true
    source: {
      script: replace(script, '\r', '')
    }
  }
}

output vmName string = vm.name
output nicName string = networkInterface.name
output primaryPrivateIpAddress string = primaryPrivateIpAddress
output publicIpAddress string = publicIp.properties.ipAddress
