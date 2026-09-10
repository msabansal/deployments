#!/bin/bash
set -euo pipefail
export LC_ALL=C
unit='__UNIT__'
port=__PORT__
peer='__CLIENT_IP__'
server='__SERVER_IP__'

for tool in iperf3 ping python3 ss systemd-run timeout; do
  command -v "$tool" >/dev/null || { echo "Missing $tool; run update-network-tools.ps1 first." >&2; exit 1; }
done
listeners=$(ss -H -ltn "sport = :$port")
if [ -n "$listeners" ]; then
  echo "TCP port $port is already occupied; no existing server will be stopped." >&2
  exit 1
fi

# Ping in this direction before launching the server, so a ping failure leaves no server.
if ! ping_report=$(timeout 20s ping -n -q -c 4 -W 2 "$peer"); then
  printf '%s\n' "$ping_report" >&2
  echo "Azure-to-on-premises ping failed or timed out." >&2
  exit 1
fi
PING_REPORT="$ping_report" python3 - <<'PY'
import json, os, re
text = os.environ["PING_REPORT"]
loss = re.search(r"([\d.]+)% packet loss", text)
rtt = re.search(r"= [\d.]+/([\d.]+)/", text)
if not loss or not rtt:
    raise ValueError("Could not parse ping result: " + text)
print(json.dumps({"ping_loss_percent": float(loss[1]), "ping_average_ms": float(rtt[1])}))
PY

systemd-run --quiet --collect --unit="$unit" \
  --property=Type=exec --property=RuntimeMaxSec=__LIFETIME__s \
  --property=TimeoutStopSec=5s --property=KillMode=control-group \
  "$(command -v iperf3)" -s -B "$server" -p "$port"

for attempt in {1..10}; do
  pid=$(systemctl show "$unit" --property=MainPID --value)
  listeners=$(ss -H -ltnp "sport = :$port")
  if [ "$pid" != "0" ] && [[ "$listeners" == *"pid=$pid,"* ]]; then
    exit 0
  fi
  if ! systemctl is-active --quiet "$unit"; then
    journalctl -u "$unit" -n 10 --no-pager >&2
    echo "Owned iperf3 server failed to start." >&2
    exit 1
  fi
  sleep 1
done
echo "Owned iperf3 server did not listen on TCP port $port within 10 seconds." >&2
exit 1
