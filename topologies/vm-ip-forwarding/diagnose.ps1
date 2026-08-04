[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $ResourceGroupName,

  [Parameter(Mandatory)]
  [string] $RouterVmName,

  [switch] $Repair
)

$ErrorActionPreference = 'Stop'

$inspect = @'
echo "=== ip_forward ==="
cat /proc/sys/net/ipv4/ip_forward
echo "=== per-interface rp_filter / send_redirects ==="
for d in /proc/sys/net/ipv4/conf/*/; do
  i=$(basename "$d")
  echo "$i rp_filter=$(cat $d/rp_filter 2>/dev/null) send_redirects=$(cat $d/send_redirects 2>/dev/null)"
done
echo "=== firewalld ==="
if systemctl is-active --quiet firewalld; then
  ZONE=$(firewall-cmd --get-default-zone)
  echo "active, default zone=$ZONE"
  echo "zone target: $(firewall-cmd --permanent --zone=$ZONE --get-target 2>/dev/null || echo unknown)"
  firewall-cmd --list-all || true
  echo "forward: $(firewall-cmd --zone=$ZONE --query-forward 2>/dev/null || echo unsupported)"
  firewall-cmd --direct --get-all-rules || true
else
  echo "inactive"
fi
echo "=== reject rules in forward path ==="
nft -a list ruleset 2>/dev/null | sed -n '/chain .*[Ff][Oo][Rr][Ww][Aa][Rr][Dd]/,/^\s*}/p' | grep -iE 'chain|reject|drop' || echo "none found via nft"
iptables -S FORWARD 2>/dev/null | grep -E 'REJECT|DROP' || echo "none found via iptables"
echo "=== iptables filter ==="
iptables -S 2>/dev/null || echo "iptables unavailable"
echo "=== nft ruleset (forward chains) ==="
nft list ruleset 2>/dev/null | grep -A6 -i "chain.*forward" || echo "nft unavailable"
echo "=== routes ==="
ip route
'@

$repair = @'
set -e
sysctl -w net.ipv4.ip_forward=1
for d in /proc/sys/net/ipv4/conf/*/; do
  [ -w "$d/rp_filter" ] && echo 0 > "$d/rp_filter" || true
  [ -w "$d/send_redirects" ] && echo 0 > "$d/send_redirects" || true
done
if systemctl is-active --quiet firewalld; then
  ZONE=$(firewall-cmd --get-default-zone)
  # The zone's trailing "reject with icmpx admin-prohibited" is what answers transit
  # traffic. Setting the target to ACCEPT removes it; nothing else reliably overrides it.
  firewall-cmd --permanent --zone="$ZONE" --set-target=ACCEPT
  firewall-cmd --permanent --zone="$ZONE" --add-forward || true
  firewall-cmd --permanent --direct --add-rule ipv4 filter FORWARD 0 -j ACCEPT || true
  firewall-cmd --reload
fi
if command -v iptables >/dev/null 2>&1; then
  iptables -P FORWARD ACCEPT || true
  while line=$(iptables -L FORWARD --line-numbers -n | awk 'NR>2 && ($1 ~ /^[0-9]+$/) && ($2 == "REJECT" || $2 == "DROP") { print $1; exit }'); [ -n "$line" ]; do
    iptables -D FORWARD "$line" || break
  done
  iptables -C FORWARD -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -j ACCEPT
fi
echo "repair complete; ip_forward=$(cat /proc/sys/net/ipv4/ip_forward)"
'@

$script = if ($Repair) { "$repair`n$inspect" } else { $inspect }

az vm run-command invoke `
  --resource-group $ResourceGroupName `
  --name $RouterVmName `
  --command-id RunShellScript `
  --scripts $script `
  --query "value[].message" `
  -o tsv

if ($LASTEXITCODE -ne 0) {
  throw "Run command failed with exit code $LASTEXITCODE."
}
