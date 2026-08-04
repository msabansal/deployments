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
  echo "active"
  firewall-cmd --list-all || true
  echo "forward: $(firewall-cmd --query-forward 2>/dev/null || echo unsupported)"
  firewall-cmd --direct --get-all-rules || true
else
  echo "inactive"
fi
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
  firewall-cmd --permanent --add-forward || true
  firewall-cmd --permanent --direct --add-rule ipv4 filter FORWARD 0 -j ACCEPT || true
  firewall-cmd --reload
fi
if command -v iptables >/dev/null 2>&1; then
  iptables -P FORWARD ACCEPT || true
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
