@description('Azure region for all resources.')
param location string

@description('Name of the virtual machine.')
param vmName string

@description('Resource ID of the subnet the VM is placed in.')
param subnetId string

@description('Administrator user name.')
param adminUsername string

@description('SSH public key used for the administrator account.')
@secure()
param adminPublicKey string

@description('Virtual machine size.')
param vmSize string

@description('Enable Accelerated Networking on the network interface.')
param enableAcceleratedNetworking bool

@description('Enable Azure IP forwarding on the network interface. Required for the router VM.')
param enableIpForwarding bool

@description('Static private IP to assign. Leave empty for dynamic allocation.')
param privateIpAddress string = ''

@description('Configure the guest OS to route packets between the endpoint subnets.')
param configureOsForwarding bool

@description('First port of the test traffic range opened in the guest firewall.')
param testPortRangeStart int

@description('Last port of the test traffic range opened in the guest firewall.')
param testPortRangeEnd int

var rawScript = '''
#!/bin/bash
set -euo pipefail

ROLE=__ROLE__
PORT_START=__PORT_START__
PORT_END=__PORT_END__

if command -v tdnf >/dev/null 2>&1; then
  PKG=tdnf
elif command -v dnf >/dev/null 2>&1; then
  PKG=dnf
else
  echo "No supported package manager found" >&2
  exit 1
fi

$PKG install -y tcpdump iperf3

for optional in iproute iputils traceroute nmap-ncat bind-utils iptables; do
  $PKG install -y "$optional" || echo "optional package $optional was not installed"
done

if [ "$ROLE" = "router" ]; then
  cat >/etc/sysctl.d/99-topology-router.conf <<'SYSCTL'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
SYSCTL

  # rp_filter and send_redirects are per-interface settings. Writing the "all" and
  # "default" keys does not change interfaces that already exist, so pin each one.
  for dir in /proc/sys/net/ipv4/conf/*/; do
    iface=$(basename "$dir")
    case "$iface" in
      all|default) continue ;;
    esac
    echo "net.ipv4.conf.${iface}.rp_filter = 0" >>/etc/sysctl.d/99-topology-router.conf
    echo "net.ipv4.conf.${iface}.send_redirects = 0" >>/etc/sysctl.d/99-topology-router.conf
  done
else
  cat >/etc/sysctl.d/99-topology-endpoint.conf <<'SYSCTL'
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
SYSCTL
fi

sysctl --system >/dev/null

if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port=${PORT_START}-${PORT_END}/tcp
  firewall-cmd --permanent --add-port=${PORT_START}-${PORT_END}/udp
  firewall-cmd --permanent --add-protocol=icmp || true

  if [ "$ROLE" = "router" ]; then
    # firewalld runs on its own nftables table, so plain iptables FORWARD rules cannot
    # override it. Intra-zone forwarding must be allowed through firewalld itself, and
    # the direct rule keeps forwarding working across a firewall-cmd --reload.
    firewall-cmd --permanent --add-forward || true
    firewall-cmd --permanent --direct --add-rule ipv4 filter FORWARD 0 -j ACCEPT || true
    firewall-cmd --permanent --direct --add-rule ipv6 filter FORWARD 0 -j ACCEPT || true
  fi

  firewall-cmd --reload
fi

# Applied whether or not firewalld is present, because some images ship a bare
# iptables/nftables ruleset with no firewalld service.
if command -v iptables >/dev/null 2>&1; then
  ensure_input() {
    if ! iptables -C INPUT "$@" -j ACCEPT 2>/dev/null; then
      iptables -I INPUT 1 "$@" -j ACCEPT
    fi
  }

  ensure_input -p tcp --dport ${PORT_START}:${PORT_END}
  ensure_input -p udp --dport ${PORT_START}:${PORT_END}
  ensure_input -p icmp

  if [ "$ROLE" = "router" ]; then
    iptables -P FORWARD ACCEPT || true
    if ! iptables -C FORWARD -j ACCEPT 2>/dev/null; then
      iptables -I FORWARD 1 -j ACCEPT
    fi
  fi

  if command -v iptables-save >/dev/null 2>&1; then
    mkdir -p /etc/systemd/scripts
    iptables-save >/etc/systemd/scripts/ip4save || true
  fi
fi

if [ "$ROLE" = "router" ]; then
  forwarding=$(cat /proc/sys/net/ipv4/ip_forward)
  echo "ip_forward=${forwarding}"
  if [ "$forwarding" != "1" ]; then
    echo "IP forwarding is not enabled on the router VM" >&2
    exit 1
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    echo "firewalld forward policy: $(firewall-cmd --query-forward || true)"
  fi
fi

echo "configuration complete"
'''

var script = replace(
  replace(
    replace(rawScript, '__ROLE__', configureOsForwarding ? 'router' : 'endpoint'),
    '__PORT_START__',
    string(testPortRangeStart)
  ),
  '__PORT_END__',
  string(testPortRangeEnd)
)

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: '${vmName}-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource networkInterface 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${vmName}-nic'
  location: location
  properties: {
    enableAcceleratedNetworking: enableAcceleratedNetworking
    enableIPForwarding: enableIpForwarding
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          privateIPAllocationMethod: empty(privateIpAddress) ? 'Dynamic' : 'Static'
          privateIPAddress: empty(privateIpAddress) ? null : privateIpAddress
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

resource configure 'Microsoft.Compute/virtualMachines/runCommands@2024-07-01' = {
  name: 'configure-topology'
  parent: vm
  location: location
  properties: {
    treatFailureAsDeploymentFailure: true
    source: {
      script: script
    }
  }
}

output vmId string = vm.id
output privateIpAddress string = networkInterface.properties.ipConfigurations[0].properties.privateIPAddress
output publicIpAddress string = publicIp.properties.ipAddress
