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

var baseScript = '''
#!/bin/bash
set -euo pipefail

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

if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port=${PORT_START}-${PORT_END}/tcp
  firewall-cmd --permanent --add-port=${PORT_START}-${PORT_END}/udp
  firewall-cmd --permanent --add-protocol=icmp || true
  firewall-cmd --reload
elif command -v iptables >/dev/null 2>&1; then
  iptables -C INPUT -p tcp --dport ${PORT_START}:${PORT_END} -j ACCEPT 2>/dev/null \
    || iptables -I INPUT 1 -p tcp --dport ${PORT_START}:${PORT_END} -j ACCEPT
  iptables -C INPUT -p udp --dport ${PORT_START}:${PORT_END} -j ACCEPT 2>/dev/null \
    || iptables -I INPUT 1 -p udp --dport ${PORT_START}:${PORT_END} -j ACCEPT
  iptables -C INPUT -p icmp -j ACCEPT 2>/dev/null \
    || iptables -I INPUT 1 -p icmp -j ACCEPT
fi
'''

// ICMP redirects are ignored so that traffic keeps traversing the router VM even though the
// router forwards packets back out of the interface they arrived on.
var endpointScript = '''
cat >/etc/sysctl.d/99-topology-endpoint.conf <<'SYSCTL'
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
SYSCTL
sysctl --system
'''

var routerScript = '''
cat >/etc/sysctl.d/99-topology-router.conf <<'SYSCTL'
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv6.conf.all.forwarding = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
SYSCTL
sysctl --system

iptables -P FORWARD ACCEPT
iptables -C FORWARD -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -j ACCEPT
'''

var persistScript = '''
if command -v iptables-save >/dev/null 2>&1; then
  mkdir -p /etc/systemd/scripts
  iptables-save > /etc/systemd/scripts/ip4save || true
fi

echo "configuration complete"
'''

var script = replace(
  replace(
    '${baseScript}${configureOsForwarding ? routerScript : endpointScript}${persistScript}',
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
