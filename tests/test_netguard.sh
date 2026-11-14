# shellcheck shell=bash disable=SC2016  # the checks are bash -c scripts, expanded when they run
# Network guard (#2): the nftables rules the guest loads, built by the guard script that
# setup_netguard installs. The script is taken from what would be sent to the VM and run here
# with stub ip, nft and sleep commands.

# guard_rules ALLOW_LAN [GW4] [GW6]: prints the ruleset the guard loads, and exits as the guard
# does, for a guest with these gateways (default 192.168.1.1 and fe80::1; "-" for none), the
# on-link networks 192.168.1.0/24 and 2001:db8:1::/64, and a desktop with the addresses
# 192.168.122.1, 10.99.0.1 and 2001:db8:9::5.
guard_rules() {
  local d=$T/ng; rm -rf "$d"; mkdir -p "$d/bin"
  bash -c 'source ./vm-browser.sh; LAN=0; host_addrs() { echo "192.168.122.1 10.99.0.1 2001:db8:9::5"; }; vmsh() { printf "%s\n" "$@" > "$T/ng/args"; cat; }; setup_netguard' > "$d/sent" 2>/dev/null
  sed -n "/^cat > \/usr\/local\/sbin\/vm-browser-netguard <<'GUARD'$/,/^GUARD$/p" "$d/sent" | sed '1d;$d' \
    | sed "s|/etc/vm-browser/netguard.conf|$d/conf|" > "$d/guard"
  printf 'ALLOW_LAN=%s\nHOST_ADDRS=%q\n' "$1" "$(sed -n 2p "$d/args")" > "$d/conf"
  local gw4=${2:-192.168.1.1} gw6=${3:-fe80::1}
  cat > "$d/bin/ip" <<IP
#!/bin/bash
case "\$*" in
  "-4 route show default") [ "$gw4" = - ] || echo "default via $gw4 dev eth0 proto dhcp metric 100";;
  "-6 route show default") [ "$gw6" = - ] || echo "default via $gw6 dev eth0 proto ra metric 100";;
  "-4 route show scope link") echo "192.168.1.0/24 dev eth0 proto kernel scope link src 192.168.1.50";;
  "-6 route show") printf '%s\n' "2001:db8:1::/64 dev eth0 proto ra metric 100" "fe80::/64 dev eth0 proto kernel metric 1024" "unreachable 2001:db8:2::/48 dev lo"; [ "$gw6" = - ] || echo "default via $gw6 dev eth0";;
esac
IP
  printf '#!/bin/bash\ncat\n' > "$d/bin/nft"; printf '#!/bin/bash\n:\n' > "$d/bin/sleep"; chmod +x "$d/bin/"*
  PATH="$d/bin:$PATH" bash "$d/guard"
}
export -f guard_rules
# before RULES A B: true if a line with A comes before the first line with B.
before() { local a b; a=$(grep -nF -- "$2" <<< "$1" | head -1 | cut -d: -f1); b=$(grep -nF -- "$3" <<< "$1" | head -1 | cut -d: -f1); [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; }
export -f before

check "the gateway (the desktop's loopback through passt) is rejected" \
  bash -c 'r=$(guard_rules 0) && grep -q "ip daddr 192.168.1.1 counter reject" <<< "$r" && grep -q "ip6 daddr fe80::1 counter reject" <<< "$r"'
check "the desktop's own addresses, given at setup, are rejected" \
  bash -c 'r=$(guard_rules 0) && grep -q "ip daddr 192.168.122.1 counter reject" <<< "$r" && grep -q "ip daddr 10.99.0.1 counter reject" <<< "$r" && grep -q "ip6 daddr 2001:db8:9::5 counter reject" <<< "$r"'
check "setup passes the desktop's addresses, without loopback" \
  bash -c 'source ./vm-browser.sh; a=$(host_addrs); [ -n "$a" ] && ! grep -qE "(^| )(127\.|::1( |$))" <<< "$a"'
check "DNS, DHCP, neighbour discovery and replies pass before any reject or drop" \
  bash -c 'r=$(guard_rules 0) && for k in "ct state established,related accept" "th dport 53 accept" "udp dport { 67, 547 } accept" "nd-neighbor-solicit"; do before "$r" "$k" reject && before "$r" "$k" drop || exit 1; done'
check "multicast and broadcast are dropped" \
  bash -c 'r=$(guard_rules 1) && grep -q "ip daddr { 224.0.0.0/4, 255.255.255.255 } counter drop" <<< "$r" && grep -q "ip6 daddr ff00::/8 counter drop" <<< "$r"'
check "by default private, link-local and on-link networks (with the global IPv6 prefix) are rejected" \
  bash -c 'r=$(guard_rules 0) && grep -q "192.168.0.0/16, 169.254.0.0/16" <<< "$r" && grep -q "ip daddr 192.168.1.0/24 counter reject" <<< "$r" && grep -q "ip6 daddr 2001:db8:1::/64 counter reject" <<< "$r" && ! grep -q unreachable <<< "$r"'
check "--lan lets the LAN through but still rejects the gateway and the desktop's addresses" \
  bash -c 'r=$(guard_rules 1) && ! grep -q 192.168.0.0/16 <<< "$r" && ! grep -q 2001:db8:1:: <<< "$r" && grep -q "ip daddr 192.168.1.1 counter reject" <<< "$r" && grep -q "ip daddr 192.168.122.1 counter reject" <<< "$r"'
check "no IPv4 gateway yet: all IPv4 but DHCP is rejected, and the guard fails so systemd retries" \
  bash -c 'r=$(guard_rules 0 - 2>/dev/null); rc=$?; [ $rc -ne 0 ] && grep -q "meta nfproto ipv4 counter reject" <<< "$r" && before "$r" "udp dport { 67, 547 } accept" "meta nfproto ipv4"'
check "no IPv6 gateway: all IPv6 but neighbour discovery and DHCPv6 is rejected" \
  bash -c 'r=$(guard_rules 0 192.168.1.1 -) && grep -q "meta nfproto ipv6 counter reject" <<< "$r" && before "$r" "nd-router-solicit" "meta nfproto ipv6"'
check "the guard unit retries on failure and runs before sshd" \
  bash -c 'source ./vm-browser.sh; LAN=0; out=$(vmsh() { cat; }; setup_netguard 2>/dev/null); grep -qx "Restart=on-failure" <<< "$out" && grep -qx "Before=sshd.service" <<< "$out"'
check "the launcher waits for the guard to be active before it starts the browser" \
  bash -c 'grep -q "systemctl is-active --quiet vm-browser-netguard.service" vm-browser.sh'
# A stub nft that refuses any ruleset with a gateway rule, as if it didn't parse.
cat > "$T/nft-refuses" <<'STUB'
#!/bin/bash
r=$(cat); if grep -q "ip daddr 192.168.1.1" <<< "$r"; then exit 1; fi; echo "$r" > "$T/ng/loaded"
STUB
chmod +x "$T/nft-refuses"
check "a ruleset that doesn't load leaves a lockdown table, and the guard fails" \
  bash -c 'guard_rules 0 >/dev/null; cp "$T/nft-refuses" "$T/ng/bin/nft"; ! PATH="$T/ng/bin:$PATH" bash "$T/ng/guard" 2>/dev/null && grep -qx "  counter reject" "$T/ng/loaded" && ! grep -q 192.168 "$T/ng/loaded"'
check "--lan is parsed" bash -c 'source ./vm-browser.sh; parse_args --lan firefox; [ "$LAN" = 1 ]'
