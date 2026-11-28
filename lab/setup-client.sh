#!/usr/bin/env bash
# Run on the authorized auxiliary Debian host. Endpoint is the LAB-1 LAN IP.
set -euo pipefail
endpoint=${1:?LAB-1 address required}
conf=${2:?WireGuard configuration file required}
ns=rp-lab-client
if ip netns list | grep -q "^$ns "; then echo 'Namespace already exists; inspect before replacing' >&2; exit 1; fi
install -d -m 700 /root/rp-lab
sysctl -n net.ipv4.ip_forward >/root/rp-lab/ip-forward.before
ip netns add "$ns"
ip link add rp-lab-host type veth peer name rp-lab-net
ip link set rp-lab-net netns "$ns"
ip addr add 10.253.66.1/30 dev rp-lab-host
ip link set rp-lab-host up
ip -n "$ns" link set lo up
ip -n "$ns" addr add 10.253.66.2/30 dev rp-lab-net
ip -n "$ns" link set rp-lab-net up
ip -n "$ns" route add "$endpoint/32" via 10.253.66.1
sysctl -q -w net.ipv4.ip_forward=1
nft -f - <<NFT
table ip rp_lab_client {
 chain nat { type nat hook postrouting priority srcnat; policy accept;
 ip saddr 10.253.66.2 ip daddr $endpoint udp dport 24566 masquerade
 }
}
NFT
ip netns exec "$ns" ip link add wg0 type wireguard
wg-quick strip "$conf" >/root/rp-lab/client-stripped.conf
chmod 600 /root/rp-lab/client-stripped.conf
ip netns exec "$ns" wg setconf wg0 /root/rp-lab/client-stripped.conf
client_addr=$(sed -n 's/^Address = //p' "$conf")
IFS=, read -ra addresses <<<"$client_addr"
for address in "${addresses[@]}"; do ip -n "$ns" addr add "${address// /}" dev wg0; done
ip -n "$ns" link set wg0 mtu 1380 up
ip -n "$ns" route add default dev wg0
ip -n "$ns" -6 route add default dev wg0
install -d /etc/netns/"$ns"
printf 'nameserver 10.66.0.1\noptions timeout:2 attempts:2\n' >/etc/netns/"$ns"/resolv.conf
printf 'Client namespace configured: %s\n' "$ns"
