# shellcheck shell=bash disable=SC2016  # the checks are bash -c scripts, expanded when they run
# Network guard (#2): the nftables rules the guest loads, built by the guard script that
# setup_netguard installs. The script is taken from what would be sent to the VM and run here
# with stub ip and nft commands.

# guard_rules ALLOW_LAN: prints the ruleset the guard loads for a guest whose gateways are
# 192.168.1.1 and fe80::1.
guard_rules() {
  local d=$T/ng; rm -rf "$d"; mkdir -p "$d/bin"
  bash -c 'source ./vm-browser.sh; LAN=0; vmsh() { cat; }; setup_netguard' > "$d/sent" 2>/dev/null
  sed -n "/^cat > \/usr\/local\/sbin\/vm-browser-netguard <<'GUARD'$/,/^GUARD$/p" "$d/sent" | sed '1d;$d' \
    | sed "s|/etc/vm-browser/netguard.conf|$d/conf|" > "$d/guard"
  echo "ALLOW_LAN=$1" > "$d/conf"
  printf '#!/bin/bash\ncase "$*" in *-4*) echo "default via 192.168.1.1 dev eth0";; *-6*) echo "default via fe80::1 dev eth0";; esac\n' > "$d/bin/ip"
  printf '#!/bin/bash\ncat\n' > "$d/bin/nft"; chmod +x "$d/bin/ip" "$d/bin/nft"
  PATH="$d/bin:$PATH" bash "$d/guard"
}
export -f guard_rules

check "the gateway (the desktop's loopback through passt) is rejected" \
  bash -c 'r=$(guard_rules 0) && grep -q "ip daddr 192.168.1.1 counter reject" <<< "$r" && grep -q "ip6 daddr fe80::1 counter reject" <<< "$r"'
check "DNS, DHCP and replies pass before any reject" \
  bash -c 'r=$(guard_rules 0) && first=$(grep -n reject <<< "$r" | head -1 | cut -d: -f1) && for k in "ct state established,related accept" "th dport 53 accept" "udp dport { 67, 547 } accept"; do n=$(grep -nF "$k" <<< "$r" | cut -d: -f1); [ -n "$n" ] && [ "$n" -lt "$first" ] || exit 1; done'
check "by default private and link-local networks are rejected" \
  bash -c 'guard_rules 0 | grep -q "192.168.0.0/16, 169.254.0.0/16"'
check "--lan lets the LAN through but still rejects the gateway" \
  bash -c 'r=$(guard_rules 1) && ! grep -q 192.168.0.0/16 <<< "$r" && grep -q "ip daddr 192.168.1.1 counter reject" <<< "$r"'
check "--lan is parsed" bash -c 'source ./vm-browser.sh; parse_args --lan firefox; [ "$LAN" = 1 ]'
