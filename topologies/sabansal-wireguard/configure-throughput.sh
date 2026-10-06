#!/bin/bash
set -euo pipefail

enable_offloads() {
  local device=$1 feature state
  for feature in gro gso tso rx-udp-gro-forwarding; do
    case "$feature" in
      gro) state=generic-receive-offload ;;
      gso) state=generic-segmentation-offload ;;
      tso) state=tcp-segmentation-offload ;;
      *) state=$feature ;;
    esac
    if ethtool -k "$device" | grep -Eq "^[[:space:]]*$state: (on|off)$"; then
      ethtool -K "$device" "$feature" on
    else
      echo "$device: $feature is fixed or unsupported; leaving unchanged"
    fi
  done
  if ethtool -k "$device" | grep -Eq '^[[:space:]]*rx-gro-list: (on|off)$'; then
    ethtool -K "$device" rx-gro-list off
  fi
}

if [ "${1:-}" = "--tunnel-only" ]; then
  enable_offloads wg0
  exit 0
fi

if [ "${1:-}" = "--receive-affinity" ]; then
  if [ "$(nproc)" -eq 2 ] && [ -f /sys/class/net/wg0/threaded ] \
      && [ "$(cat /sys/class/net/wg0/threaded)" = 1 ]; then
    poller=
    for attempt in {1..50}; do
      if poller=$(pgrep -x 'napi/wg0-[0-9]+'); then
        break
      fi
      sleep 0.1
    done
    if [ -z "$poller" ]; then
      echo "WireGuard threaded receive poller did not appear within five seconds" >&2
      exit 1
    fi
    taskset -pc 0 "$poller"
  else
    echo "Leaving receive affinity unchanged: two-vCPU threaded NAPI is not available"
  fi
  exit 0
fi

device=$(ip -o route show default | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')
if [ -z "$device" ]; then
  echo "No default-route network interface found" >&2
  exit 1
fi
enable_offloads "$device"

vf=
for attempt in {1..30}; do
  for path in /sys/class/net/*; do
    candidate=${path##*/}
    [ "$candidate" = lo ] && continue
    if ethtool -i "$candidate" 2>/dev/null | grep -qx 'driver: mana'; then
      vf=$candidate
      break
    fi
  done
  [ -n "$vf" ] && break
  sleep 1
done
if [ -z "$vf" ]; then
  echo "No accelerated MANA interface appeared within 30 seconds" >&2
  exit 1
fi
enable_offloads "$vf"
ethtool -G "$vf" rx 2048 tx 4096

# This placement was measured on the two-vCPU MANA topology, not larger VMs.
if [ "${1:-}" = "--nic-only" ]; then
  receive_queues=("/sys/class/net/$vf"/queues/rx-*)
  ethtool -X "$vf" equal "${#receive_queues[@]}"
  # The synthetic netvsc device already has a qdisc; a second one on the VF only adds lock overhead.
  tc qdisc replace dev "$vf" root noqueue
  ethtool -g "$vf"
  tc qdisc show dev "$vf"
  echo "NIC offloads, rings, balanced RSS, and VF noqueue applied without changing IRQ affinity or MTU"
  exit 0
fi

if [ "$(nproc)" -eq 2 ] && [ -d "/sys/class/net/$vf/queues/rx-1" ]; then
  mkdir -p /etc/systemd/system/irqbalance.service.d
  cat >/etc/systemd/system/irqbalance.service.d/wireguard-throughput.conf <<'IRQBALANCE_UNIT'
[Service]
ExecStart=
ExecStart=/usr/sbin/irqbalance $IRQBALANCE_ARGS --banmod=mana
IRQBALANCE_UNIT
  systemctl daemon-reload
  if systemctl is-active --quiet irqbalance.service; then
    systemctl restart irqbalance.service
  fi
  receive_queue=
  for queue in 0 1; do
    irq=$(awk -v name="mana_q$queue@pci:" '$NF ~ "^"name {gsub(/:/, "", $1); print $1; exit}' /proc/interrupts)
    if [ -n "$irq" ] && [ "$(cat "/proc/irq/$irq/effective_affinity_list")" = 0 ]; then
      receive_queue=$queue
      break
    fi
  done
  if [ -z "$receive_queue" ]; then
    irq=$(awk '$NF ~ /^mana_q0@pci:/ {gsub(/:/, "", $1); print $1; exit}' /proc/interrupts)
    if [ -z "$irq" ]; then
      echo "MANA queue 0 IRQ could not be found" >&2
      exit 1
    fi
    echo 0 >"/proc/irq/$irq/smp_affinity_list"
    # Migration becomes effective when the next interrupt is handled.
    for attempt in {1..50}; do
      [ "$(cat "/proc/irq/$irq/effective_affinity_list")" = 0 ] && break
      sleep 0.1
    done
    if [ "$(cat "/proc/irq/$irq/effective_affinity_list")" != 0 ]; then
      echo "MANA queue 0 IRQ could not be placed on CPU 0" >&2
      exit 1
    fi
    receive_queue=0
  fi
  case "$receive_queue" in
    0) ethtool -X "$vf" weight 1 0 ;;
    1) ethtool -X "$vf" weight 0 1 ;;
    *)
      echo "Neither MANA queue has exclusive IRQ placement on CPU 0" >&2
      exit 1
      ;;
  esac
  echo "RSS uses RX queue $receive_queue, whose IRQ runs on CPU 0"
else
  echo "Leaving RSS unchanged: measured placement requires two vCPUs and two RX queues"
fi
ethtool -g "$vf"
echo "Throughput tuning applied without changing the network MTU"
