#!/bin/bash
set -euo pipefail
umask 077

export ACTION=__ACTION__
export NAMESPACE=__NAMESPACE__
export SWIFT_IP=__SWIFT_IP__
export VLAN=__VLAN__
export VNET_GUID=__VNET_GUID__
export SUBNET=__SUBNET__
export AUTH_TOKEN=__AUTH_TOKEN__
export STATE="/var/lib/swift-ilb/$NAMESPACE.json"

[[ "$NAMESPACE" =~ ^[a-zA-Z0-9_-]{1,64}$ ]]
install -d -m 0700 /var/lib/swift-ilb

cleanup() {
  if [ ! -f "$STATE" ]; then
    if ip netns list | awk '{print $1}' | grep -qx "$NAMESPACE"; then
      echo "Namespace exists without managed state; refusing untracked cleanup" >&2
      return 1
    fi
    echo "No managed SWIFT attachment remains"
    return
  fi
  python3 - <<'PY'
import json, os, pathlib, subprocess
with open(os.environ["STATE"]) as handle:
    state = json.load(handle)
if state["namespace"] != os.environ["NAMESPACE"] or state["vlan"] != int(os.environ["VLAN"]):
    raise RuntimeError("Refusing mismatched managed SWIFT state")
unit = f"swift-ilb-probe-{state['namespace']}.service"
unit_path = pathlib.Path("/etc/systemd/system") / unit
if unit_path.exists():
    subprocess.run(["systemctl", "disable", "--now", unit], check=True)
    unit_path.unlink()
    subprocess.run(["systemctl", "daemon-reload"], check=True)
pathlib.Path(f"/usr/local/sbin/swift-ilb-probe-{state['namespace']}.py").unlink(missing_ok=True)
subprocess.run([
    "/usr/local/bin/swiftcmd", "delete", "--nc-id", state["ncId"],
    "--auth-token", state["authToken"], "--namespace", state["namespace"],
    "--vlan", str(state["vlan"]),
], check=True)
os.unlink(os.environ["STATE"])
PY
}

if [ "$ACTION" = cleanup ]; then
  cleanup
  exit
fi
test "$ACTION" = create

if [ -f "$STATE" ]; then
  python3 - <<'PY'
import json, os, subprocess
with open(os.environ["STATE"]) as handle:
    state = json.load(handle)
expected = {
    "namespace": os.environ["NAMESPACE"], "ip": os.environ["SWIFT_IP"],
    "vnetGuid": os.environ["VNET_GUID"], "subnet": os.environ["SUBNET"],
    "vlan": int(os.environ["VLAN"]),
}
if any(state.get(key) != value for key, value in expected.items()):
    raise RuntimeError("Managed SWIFT state differs; run -CleanupSwift before changing the attachment")
raw = subprocess.check_output(["/usr/local/bin/swiftcmd", "get-all-ncs"], text=True)
report = json.loads(raw[raw.index("{"):])
entries = report.get("networkContainers") or report.get("NetworkContainers") or []
if not any((entry.get("networkContainerId") or entry.get("NetworkContainerId")) == state["ncId"]
           for entry in entries):
    raise RuntimeError("Managed NC is missing; run -CleanupSwift before retrying")
PY
  ip -n "$NAMESPACE" link show swift0 >/dev/null
  echo "Reusing managed SWIFT attachment"
else
  if ip netns list | awk '{print $1}' | grep -qx "$NAMESPACE"; then
    echo "Namespace exists without managed state; refusing to overwrite it" >&2
    exit 1
  fi
  log=$(mktemp /var/lib/swift-ilb/create.XXXXXX)
  trap 'rm -f "$log"' EXIT
  /usr/local/bin/swiftcmd create --auth-token "$AUTH_TOKEN" \
    --vnet-id "$VNET_GUID" --subnet "$SUBNET" --ip "$SWIFT_IP" \
    --vlan "$VLAN" --namespace "$NAMESPACE" --parent eth0 2>&1 | tee "$log"
  export NC_ID
  NC_ID=$(sed -n 's/.*generated NC id: \([0-9a-fA-F-]*\).*/\1/p' "$log")
  if ! python3 - <<'PY'
import json, os, uuid
uuid.UUID(os.environ["NC_ID"])
state = {
    "ncId": os.environ["NC_ID"], "authToken": os.environ["AUTH_TOKEN"],
    "namespace": os.environ["NAMESPACE"], "ip": os.environ["SWIFT_IP"],
    "vnetGuid": os.environ["VNET_GUID"], "subnet": os.environ["SUBNET"],
    "vlan": int(os.environ["VLAN"]),
}
path = os.environ["STATE"]
with open(path + ".tmp", "w") as handle:
    json.dump(state, handle)
os.replace(path + ".tmp", path)
PY
  then
    echo "Could not persist SWIFT state; rolling back the new NC" >&2
    /usr/local/bin/swiftcmd delete --nc-id "$NC_ID" --auth-token "$AUTH_TOKEN" \
      --namespace "$NAMESPACE" --vlan "$VLAN"
    exit 1
  fi
  echo __SWIFT_NEW_NC__
fi

# ILB floating-IP transit preserves the endpoint destination, which ipvlan-L2
# cannot demultiplex to a child owning only the router IP.
link_kind=$(ip -n "$NAMESPACE" -j -d link show dev swift0 |
  python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["linkinfo"]["info_kind"])')
if [ "$link_kind" = ipvlan ]; then
  gateway=$(ip -n "$NAMESPACE" -4 route show default | awk '$1 == "default" {print $3}')
  test -n "$gateway"
  ip -n "$NAMESPACE" link delete swift0
  ip link set "swiftvlan$VLAN" netns "$NAMESPACE"
  ip -n "$NAMESPACE" link set "swiftvlan$VLAN" down
  ip -n "$NAMESPACE" link set "swiftvlan$VLAN" name swift0
  ip -n "$NAMESPACE" address add "$SWIFT_IP/32" dev swift0
  ip -n "$NAMESPACE" link set swift0 up
  ip -n "$NAMESPACE" neigh replace "$gateway" lladdr 12:34:56:78:9a:bc nud permanent dev swift0
  ip -n "$NAMESPACE" route replace default via "$gateway" dev swift0 onlink
elif [ "$link_kind" != vlan ]; then
  echo "Unexpected managed SWIFT interface kind: $link_kind" >&2
  exit 1
fi
ip -n "$NAMESPACE" -j -d link show dev swift0 |
  python3 -c 'import json,os,sys; link=json.load(sys.stdin)[0]["linkinfo"]; assert link["info_kind"] == "vlan" and link["info_data"]["id"] == int(os.environ["VLAN"]), "SWIFT routing VLAN mismatch"'

ip -n "$NAMESPACE" -4 -o address show dev swift0 |
  awk '{print $4}' | grep -qx "$SWIFT_IP/32"
ip netns exec "$NAMESPACE" sysctl -w \
  net.ipv4.ip_forward=1 \
  net.ipv4.conf.all.rp_filter=0 \
  net.ipv4.conf.default.rp_filter=0 \
  net.ipv4.conf.swift0.rp_filter=0 \
  net.ipv4.conf.all.send_redirects=0 \
  net.ipv4.conf.default.send_redirects=0 \
  net.ipv4.conf.swift0.send_redirects=0 \
  net.ipv4.conf.all.accept_redirects=0 \
  net.ipv4.conf.default.accept_redirects=0 \
  net.ipv4.conf.swift0.accept_redirects=0 >/dev/null
ip netns exec "$NAMESPACE" iptables -P FORWARD ACCEPT

python3 - <<'PY'
import os, pathlib, shutil, subprocess
namespace = os.environ["NAMESPACE"]
unit = f"swift-ilb-probe-{namespace}.service"
path = pathlib.Path("/etc/systemd/system") / unit
probe_script = pathlib.Path(f"/usr/local/sbin/swift-ilb-probe-{namespace}.py")
probe_script.write_text("""import socket
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", 22))
s.listen(16)
while True:
    connection, address = s.accept()
    connection.close()
""")
path.write_text(f"""[Unit]
Description=TCP health probe inside SWIFT routing namespace
After=network-online.target
Wants=network-online.target

[Service]
NetworkNamespacePath=/run/netns/{namespace}
ExecStart={shutil.which("python3")} -u {probe_script}
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
""")
subprocess.run(["systemctl", "daemon-reload"], check=True)
subprocess.run(["systemctl", "enable", "--now", unit], check=True)
subprocess.run(["systemctl", "restart", unit], check=True)
PY
for attempt in $(seq 1 20); do
  if ip netns exec "$NAMESPACE" ss -ltn 'sport = :22' | grep -q LISTEN; then
    echo __SWIFT_ROUTER_READY__
    exit
  fi
  sleep 0.5
done
systemctl status "swift-ilb-probe-$NAMESPACE.service" --no-pager >&2
echo "The SWIFT namespace health probe did not start" >&2
exit 1
