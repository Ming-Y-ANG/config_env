#!/bin/sh
#vps="38.55.199.15"
#gtkey="27886729822BFC42209A11B60DBD1415777F0AC21504506603429512A62C2E6A"
vps="47.109.150.68"
gtkey="5E5B8E65A639239FB11F0ED6B01F72DAF53DBE6A77D7E5529791169CB669685C"
dev="gt-tun0"
localip="10.255.255.2"
remoteip="10.255.255.1"
dev1="apn01"
dev2="apn11"
table1="200"
table2="201"
priority1="150"
priority2="151"
priority3="152"

killall glorytun
sleep 1
echo $gtkey > /tmp/glorytun-vpn.key
glorytun keyfile /tmp/glorytun-vpn.key port 65001 host $vps dev $dev mptcp chacha20 retry count -1 const 500000 timeout 10000 buffer-size 65536 keepalive > /var/log/gt-log 2>&1 &
sleep 2
ifconfig $dev $localip pointopoint $remoteip up
ip link set dev $dev txqueuelen 1000
#cellular1 ip/gw
cellular1=$(ip addr show dev $dev1 | grep -w inet)
dev1_ip=$(echo "$cellular1" | awk '{print $2}')
dev1_gw=$(echo "$cellular1" | awk '{print $4}' | cut -d'/' -f1)
echo "dev1_ip: $dev1_ip, dev1_gw: $dev1_gw"
#cellular2 ip/gw
cellular2=$(ip addr show dev $dev2 | grep -w inet)
dev2_ip=$(echo "$cellular2" | awk '{print $2}')
dev2_gw=$(echo "$cellular2" | awk '{print $4}' | cut -d'/' -f1)
echo "dev2_ip: $dev2_ip, dev2_gw: $dev2_gw"
ip route flush default
ip route add default via $remoteip dev $dev proto static
ip route add default via $dev1_gw dev $dev1 proto static metric $table1
ip route add default via $dev2_gw dev $dev2 proto static metric $table2

#ip route del $vps 2>/dev/null || true
ip route replace $vps metric 1 \
    nexthop via $dev1_gw dev apn01 weight 5 \
    nexthop via $dev2_gw dev apn11 weight 6

ip rule del oif $dev1 lookup $table1 2>/dev/null || true
ip rule add oif $dev1 lookup $table1 priority $priority1
ip rule del oif $dev2 lookup $table2 2>/dev/null || true
ip rule add oif $dev2 lookup $table2 priority $priority2

ip rule del lookup 1200 2>/dev/null || true
ip rule add from $localip table 1200 priority $priority3
ip rule del oif $dev lookup 1200 2>/dev/null || true
ip rule add oif $dev lookup 1200 priority $priority3
ip route replace $localip dev $dev scope link table 1200
ip route replace default via $remoteip dev $dev table 1200

iptables -t nat -D POSTROUTING -o $dev -j MASQUERADE 2>/dev/null || true
iptables -t nat -A POSTROUTING -o $dev -j MASQUERADE

