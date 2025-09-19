#!/bin/sh
dev1="apn01"
dev2="apn11"
priority1="150"
priority2="151"
table1="200"
table2="201"

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

ip rule del lookup $table1 2>/dev/null || true
ip rule del lookup $table2 2>/dev/null || true
ip route flush table $table1 2>/dev/null || true
ip route flush table $table2 2>/dev/null || true

# This creates two different routing tables, that we use based on the source-address.
ip rule add from $dev1_ip table $table1 priority $priority1
ip rule add from $dev2_ip table $table2 priority $priority2

# Configure the two different routing tables
ip route add $dev1_ip dev $dev1 scope link table $table1
ip route add default via $dev1_gw dev $dev1 table $table1

ip route add $dev2_ip dev $dev2 scope link table $table2
ip route add default via $dev2_gw dev $dev2 table $table2

