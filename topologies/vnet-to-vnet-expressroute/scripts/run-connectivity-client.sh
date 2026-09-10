#!/bin/bash
set -euo pipefail
export LC_ALL=C
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
for tool in iperf3 ping python3 timeout; do
  command -v "$tool" >/dev/null || { echo "Missing $tool; run update-network-tools.ps1 first." >&2; exit 1; }
done
if ! timeout 20s ping -n -q -c 4 -W 2 '__SERVER_IP__' >"$work/ping"; then
  cat "$work/ping" >&2
  echo "On-premises-to-Azure ping failed or timed out." >&2
  exit 1
fi

rc=0
timeout --signal=TERM --kill-after=5s __CLIENT_TIMEOUT__s \
  iperf3 -c '__SERVER_IP__' -B '__CLIENT_IP__' -p __PORT__ -P __STREAMS__ \
  -t __DURATION__ __DIRECTION__ --json >"$work/report.json" 2>"$work/error" || rc=$?
if [ "$rc" -ne 0 ]; then
  tail -c 1200 "$work/report.json" >&2
  tail -c 400 "$work/error" >&2
  echo "iperf3 client failed (exit $rc)." >&2
  exit "$rc"
fi

# The full per-stream iperf JSON exceeds Azure Run Command's last-4-KB output limit.
python3 - "$work/report.json" "$work/ping" <<'PY'
import json, re, sys
with open(sys.argv[1]) as handle:
    report = json.load(handle)
if report.get("error"):
    sys.exit("iperf3: " + report["error"])
with open(sys.argv[2]) as handle:
    ping = handle.read()
loss = re.search(r"([\d.]+)% packet loss", ping)
rtt = re.search(r"= [\d.]+/([\d.]+)/", ping)
if not loss or not rtt:
    raise ValueError("Could not parse ping result: " + ping)
sent = report["end"]["sum_sent"]
received = report["end"]["sum_received"]
summary = {
    "ping_loss_percent": float(loss[1]),
    "ping_average_ms": float(rtt[1]),
    "seconds": sent["seconds"],
    "bytes_sent": sent["bytes"],
    "bits_per_second_sent": sent["bits_per_second"],
    "bits_per_second_received": received["bits_per_second"],
    "retransmits": sent["retransmits"],
}
print(json.dumps(summary, separators=(",", ":"), allow_nan=False))
PY
