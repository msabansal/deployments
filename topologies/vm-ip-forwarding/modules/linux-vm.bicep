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
  ZONE=$(firewall-cmd --get-default-zone)
  echo "firewalld default zone: ${ZONE}"

  firewall-cmd --permanent --zone="$ZONE" --add-port=${PORT_START}-${PORT_END}/tcp
  firewall-cmd --permanent --zone="$ZONE" --add-port=${PORT_START}-${PORT_END}/udp
  firewall-cmd --permanent --zone="$ZONE" --add-protocol=icmp || true

  if [ "$ROLE" = "router" ]; then
    # A firewalld zone ends with an implicit "reject with icmpx admin-prohibited", which is
    # what a router returns for transit traffic. That reject is emitted from firewalld's own
    # inet firewalld nftables table, so an iptables FORWARD ACCEPT rule cannot override it
    # and a direct rule only wins if it is evaluated first. Setting the zone target to ACCEPT
    # removes the reject outright, which is the only reliable fix.
    firewall-cmd --permanent --zone="$ZONE" --set-target=ACCEPT

    # Allow traffic to be forwarded back out of the interface it arrived on. Supported from
    # firewalld 0.9; older builds are already covered by the ACCEPT target above.
    firewall-cmd --permanent --zone="$ZONE" --add-forward || \
      echo "firewalld does not support --add-forward; relying on the ACCEPT zone target"

    # Belt and braces for builds that keep a reject in the forward path regardless of target.
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

    # Drop any REJECT/DROP rule already sitting in the FORWARD chain, otherwise it still
    # matches transit traffic ahead of the rules appended below.
    while iptables -L FORWARD --line-numbers -n 2>/dev/null | awk 'NR>2 && ($1 ~ /^[0-9]+$/) && ($2 == "REJECT" || $2 == "DROP") { print $1; exit }' | grep -q .; do
      line=$(iptables -L FORWARD --line-numbers -n | awk 'NR>2 && ($1 ~ /^[0-9]+$/) && ($2 == "REJECT" || $2 == "DROP") { print $1; exit }')
      iptables -D FORWARD "$line" || break
    done

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
  forwarding_ok=1
  forwarding=$(cat /proc/sys/net/ipv4/ip_forward)
  echo "ip_forward=${forwarding}"
  if [ "$forwarding" != "1" ]; then
    echo "IP forwarding is not enabled on the router VM" >&2
    exit 1
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    ZONE=$(firewall-cmd --get-default-zone)
    target=$(firewall-cmd --permanent --zone="$ZONE" --get-target 2>/dev/null || echo unknown)
    echo "firewalld zone target: ${target}"
    echo "firewalld intra-zone forward: $(firewall-cmd --zone="$ZONE" --query-forward || true)"

    # firewalld always keeps a trailing "reject with icmpx admin-prohibited" at the end of
    # filter_FORWARD, and that rule cannot be removed while firewalld is running. It is only
    # ever reached when nothing accepted the packet earlier, so what has to be verified is
    # that the zone target is ACCEPT, which makes firewalld put a catch-all accept in the
    # policy chain that runs first. Scanning the ruleset for the words reject or drop instead
    # would flag both that unreachable rule and legitimate ones such as "ct state invalid drop".
    if [ "$target" != "ACCEPT" ]; then
      echo "firewalld zone ${ZONE} has target ${target}; transit traffic would be rejected with ICMP admin-prohibited" >&2
      forwarding_ok=0
    fi

    if command -v nft >/dev/null 2>&1; then
      policy_chain=$(nft list chain inet firewalld filter_FORWARD_POLICIES 2>/dev/null || true)
      if [ -n "$policy_chain" ] && ! echo "$policy_chain" | grep -qE '^[[:space:]]*accept([[:space:]]|$)'; then
        echo "the firewalld forward policy chain has no catch-all accept, so the trailing reject is reachable:" >&2
        echo "$policy_chain" >&2
        forwarding_ok=0
      fi
    fi
  elif command -v iptables >/dev/null 2>&1; then
    # No firewalld, so the FORWARD chain is the whole story.
    if iptables -S FORWARD 2>/dev/null | grep -qE '^-P FORWARD (DROP|REJECT)'; then
      echo "the iptables FORWARD policy is not ACCEPT" >&2
      iptables -S FORWARD >&2
      forwarding_ok=0
    fi

    if iptables -S FORWARD 2>/dev/null | grep -qE '^-A FORWARD -j (REJECT|DROP)$'; then
      echo "an unconditional REJECT or DROP remains in the iptables FORWARD chain" >&2
      iptables -S FORWARD >&2
      forwarding_ok=0
    fi
  fi

  if [ "$forwarding_ok" != "1" ]; then
    exit 1
  fi

  echo "router forwarding path is clear"
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
