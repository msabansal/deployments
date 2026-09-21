#!/bin/bash
set -euo pipefail

PEER_SOURCE='__PEER_SOURCE__'
if command -v tdnf >/dev/null 2>&1; then
  PKG=tdnf
elif command -v dnf >/dev/null 2>&1; then
  PKG=dnf
else
  echo "Azure Linux tdnf or dnf is required." >&2
  exit 1
fi

"$PKG" install -y iperf3 tcpdump iproute iputils traceroute nmap-ncat bind-utils python3
for tool in iperf3 tcpdump ip ping traceroute ncat dig python3 timeout systemctl systemd-run ss; do
  command -v "$tool" >/dev/null || { echo "Required tool missing: $tool" >&2; exit 1; }
done
if [ -z "$PEER_SOURCE" ]; then
  echo "Network tools ready; no peer source supplied, guest firewall unchanged."
  exit 0
fi
python3 - "$PEER_SOURCE" <<'PY'
import ipaddress, sys
source = ipaddress.ip_network(sys.argv[1], strict=False)
if source.version != 4:
    raise ValueError("Peer source must be IPv4")
PY

if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  # Use the interface towards the peer, not an unrelated default zone.
  PEER_IP=${PEER_SOURCE%/*}
  IFACE=$(ip -j route get "$PEER_IP" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["dev"])')
  zone_status=0
  ZONE=$(firewall-cmd --get-zone-of-interface="$IFACE" 2>&1) || zone_status=$?
  if [ "$zone_status" -eq 2 ] && [ "$ZONE" = "no zone" ]; then
    # Unassigned interfaces use the default zone; firewalld reports exit 2.
    ZONE=$(firewall-cmd --get-default-zone)
  elif [ "$zone_status" -ne 0 ]; then
    echo "Could not resolve firewalld zone for $IFACE: $ZONE" >&2
    exit "$zone_status"
  elif [ -z "$ZONE" ] || [ "$ZONE" = "no zone" ]; then
    ZONE=$(firewall-cmd --get-default-zone)
  fi
  for traffic in 'port port="5201-5210" protocol="tcp"' 'port port="5201-5210" protocol="udp"' 'protocol value="icmp"'; do
    RULE="rule family=\"ipv4\" priority=\"-100\" source address=\"$PEER_SOURCE\" $traffic accept"
    firewall-cmd --permanent --zone="$ZONE" --add-rich-rule="$RULE"
    firewall-cmd --zone="$ZONE" --add-rich-rule="$RULE"
  done
else
  # Native nftables policies need policy-specific integration; don't pretend that an
  # iptables ACCEPT overrides a separate nftables input base chain.
  if command -v nft >/dev/null 2>&1; then
    nft -j list ruleset | python3 -c '
import json, sys
for item in json.load(sys.stdin)["nftables"]:
    chain = item.get("chain", {})
    if chain.get("family") in ("ip", "inet") and chain.get("hook") == "input" and not (
        chain.get("family") == "ip" and chain.get("table") == "filter" and chain.get("name") == "INPUT"
    ):
        sys.exit("Unsupported native nftables INPUT policy: configure peer-scoped rules in its persistent policy before retrying.")
'
  fi
  if command -v iptables >/dev/null 2>&1; then
    # Persist only our additions, not a snapshot of somebody else's firewall.
    install -d -m 755 /usr/local/libexec
    cat >/usr/local/libexec/er-network-tools-firewall <<'RULES'
#!/bin/bash
set -euo pipefail
PEER_SOURCE='__PEER_SOURCE__'
ensure_input() {
  local rc=0
  iptables -w 10 -C INPUT -s "$PEER_SOURCE" "$@" -j ACCEPT || rc=$?
  case "$rc" in
    0) ;;
    1) iptables -w 10 -I INPUT 1 -s "$PEER_SOURCE" "$@" -j ACCEPT ;;
    *) echo "Could not inspect iptables INPUT (exit $rc)" >&2; exit "$rc" ;;
  esac
}
ensure_input -p tcp --dport 5201:5210
ensure_input -p udp --dport 5201:5210
ensure_input -p icmp
RULES
    chmod 755 /usr/local/libexec/er-network-tools-firewall
    cat >/etc/systemd/system/er-network-tools-firewall.service <<'UNIT'
[Unit]
Description=Peer-scoped ExpressRoute connectivity test INPUT rules
After=iptables.service nftables.service
Before=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/er-network-tools-firewall
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable er-network-tools-firewall.service
    systemctl restart er-network-tools-firewall.service
  else
    echo "No supported guest firewall tool found; no firewall package or policy installed."
  fi
fi

echo "Network tools ready; peer source $PEER_SOURCE; TCP/UDP 5201-5210 and ICMP. No permanent iperf3 server."
