#!/bin/sh
# =============================================================================
# 脚本：glorytun-tcp.sh
# 功能：建立 GloryTun VPN 隧道，并配置策略路由实现双网卡分流
# 用法：$0 {start|stop|restart}
# =============================================================================

# ========================= 可配置参数（可按需修改） ===========================
VPS="47.109.150.68"
GTKEY="5E5B8E65A639239FB11F0ED6B01F72DAF53DBE6A77D7E5529791169CB669685C"
DEV="gt-tun0"                      # VPN 隧道设备名
LOCALIP="10.255.255.2"            # 本地隧道 IP
REMOTEIP="10.255.255.1"           # 对端隧道 IP
DEV1="apn01"                      # 第一个物理网卡
DEV2="apn11"                      # 第二个物理网卡
TABLE1=200                        # 第一个网卡使用的路由表 ID
TABLE2=201                        # 第二个网卡使用的路由表 ID
PRIORITY1=150                     # 第一个网卡的策略优先级
PRIORITY2=151                     # 第二个网卡的策略优先级
PRIORITY3=152                     # 隧道自身流量的策略优先级
TUNNEL_TABLE=1200                 # 隧道内部路由表

# 以下变量在运行时动态获取
DEV1_IP=""
DEV1_GW=""
DEV2_IP=""
DEV2_GW=""
# =============================================================================

# ----------------------------- 工具函数 ---------------------------------------
# 获取两个物理网卡的 IP 和网关
get_network_info() {
    #local cell1 cell2
    #cell1=$(ip addr show dev "$DEV1" 2>/dev/null | grep -w inet | head -1)
    #cell2=$(ip addr show dev "$DEV2" 2>/dev/null | grep -w inet | head -1)

    #if [ -z "$cell1" ]; then
    #    echo "ERROR: No IP found on $DEV1" >&2
    #    return 1
    #fi
    #if [ -z "$cell2" ]; then
    #    echo "ERROR: No IP found on $DEV2" >&2
    #    return 1
    #fi

    #DEV1_IP=$(echo "$cell1" | awk '{print $2}')
    #DEV1_GW=$(echo "$cell1" | awk '{print $4}' | cut -d'/' -f1)
    #DEV2_IP=$(echo "$cell2" | awk '{print $2}')
    #DEV2_GW=$(echo "$cell2" | awk '{print $4}' | cut -d'/' -f1)
	# 获取 IP（方法不变）
    DEV1_IP=$(ip -4 addr show dev "$DEV1" | grep -w inet | awk '{print $2}' | head -1)
    DEV2_IP=$(ip -4 addr show dev "$DEV2" | grep -w inet | awk '{print $2}' | head -1)

    # 获取网关（从路由表中提取）
    DEV1_GW=$(ip route show default | grep -w "dev $DEV1" | awk '{print $3}' | head -1)
    DEV2_GW=$(ip route show default | grep -w "dev $DEV2" | awk '{print $3}' | head -1)

    # 如果某个接口没有默认路由，尝试获取该接口的下一跳（非默认）
    [ -z "$DEV1_GW" ] && DEV1_GW=$(ip route show dev "$DEV1" | grep -v default | grep via | awk '{print $3}' | head -1)
    [ -z "$DEV2_GW" ] && DEV2_GW=$(ip route show dev "$DEV2" | grep -v default | grep via | awk '{print $3}' | head -1)

    # 输出并检查
    echo "DEV1: $DEV1_IP -> $DEV1_GW"
    echo "DEV2: $DEV2_IP -> $DEV2_GW"
    [ -z "$DEV1_GW" ] || [ -z "$DEV2_GW" ] && return 1
    return 0
}

# ----------------------------- 清理函数（stop 的核心） -----------------------
# 清理所有由本脚本添加的配置（iptables、策略规则、路由、隧道进程）
clean_all() {
    echo "Cleaning up all configurations..."

    # 1. 删除 iptables NAT 规则
    echo "  - Removing iptables MASQUERADE rule..."
    iptables -t nat -D POSTROUTING -o "$DEV" -j MASQUERADE 2>/dev/null || true

    # 2. 删除策略规则（注意顺序：先删优先级高的？无所谓，只要匹配即可）
    echo "  - Removing policy rules..."
    ip rule del oif "$DEV1" lookup "$TABLE1" priority "$PRIORITY1" 2>/dev/null || true
    ip rule del oif "$DEV2" lookup "$TABLE2" priority "$PRIORITY2" 2>/dev/null || true
    ip rule del from "$LOCALIP" table "$TUNNEL_TABLE" priority "$PRIORITY3" 2>/dev/null || true
    ip rule del oif "$DEV" lookup "$TUNNEL_TABLE" priority "$PRIORITY3" 2>/dev/null || true

    # 3. 删除我们添加的路由
    echo "  - Removing routes..."
    # 删除多路径路由（到 VPS 的负载均衡路由）
    ip route del "$VPS" metric 1 2>/dev/null || true
    # 删除默认路由（三条）
    ip route del default via "$REMOTEIP" dev "$DEV" proto static 2>/dev/null || true
    # 注意：如果默认路由不存在，忽略错误
    if [ -n "$DEV1_GW" ]; then
        ip route del default via "$DEV1_GW" dev "$DEV1" proto static metric "$TABLE1" 2>/dev/null || true
    fi
    if [ -n "$DEV2_GW" ]; then
        ip route del default via "$DEV2_GW" dev "$DEV2" proto static metric "$TABLE2" 2>/dev/null || true
    fi
    # 删除隧道内部路由表 1200 中的条目
    ip route del "$LOCALIP" dev "$DEV" scope link table "$TUNNEL_TABLE" 2>/dev/null || true
    ip route del default via "$REMOTEIP" dev "$DEV" table "$TUNNEL_TABLE" 2>/dev/null || true

    # 4. 停止 glorytun 进程并关闭隧道设备
    echo "  - Stopping glorytun and bringing tunnel down..."
    killall glorytun 2>/dev/null || true
    ifconfig "$DEV" down 2>/dev/null || ip link set "$DEV" down 2>/dev/null || true

    # 5. 删除临时密钥文件（可选）
    rm -f /tmp/glorytun-vpn.key

    echo "Cleanup finished."
}

# ----------------------------- 添加函数（start 的核心） -----------------------
# 启动 glorytun 隧道
start_tunnel() {
    echo "Starting glorytun..."
    echo "$GTKEY" > /tmp/glorytun-vpn.key
    # 启动后台进程，日志输出到 /var/log/gt-log
    glorytun keyfile /tmp/glorytun-vpn.key port 65001 host "$VPS" dev "$DEV" mptcp chacha20 retry count -1 const 500000 timeout 10000 buffer-size 65536 keepalive > /var/log/gt-log 2>&1 &
    sleep 2  # 等待设备创建
    # 配置隧道 IP
    ifconfig "$DEV" "$LOCALIP" pointopoint "$REMOTEIP" up
    ip link set dev "$DEV" txqueuelen 1000
    echo "Tunnel $DEV is up."
}

# 添加路由（默认路由和多路径路由）
add_routes() {
    echo "Adding routes..."
    # 刷新默认路由（原脚本行为）
    ip route flush default
    # 添加三条默认路由（隧道优先，metric 较小但原脚本没有指定 metric，默认是 0，会优先于其它）
    ip route add default via "$REMOTEIP" dev "$DEV" proto static
    ip route add default via "$DEV1_GW" dev "$DEV1" proto static metric "$TABLE1"
    ip route add default via "$DEV2_GW" dev "$DEV2" proto static metric "$TABLE2"
    # 添加多路径路由到 VPS
    ip route replace "$VPS" metric 1 \
        nexthop via "$DEV1_GW" dev "$DEV1" weight 5 \
        nexthop via "$DEV2_GW" dev "$DEV2" weight 6
    echo "Routes added."
}

# 添加策略规则
add_policy_rules() {
    echo "Adding policy rules..."
    ip rule add oif "$DEV1" lookup "$TABLE1" priority "$PRIORITY1"
    ip rule add oif "$DEV2" lookup "$TABLE2" priority "$PRIORITY2"
    ip rule add from "$LOCALIP" table "$TUNNEL_TABLE" priority "$PRIORITY3"
    ip rule add oif "$DEV" lookup "$TUNNEL_TABLE" priority "$PRIORITY3"
    # 配置隧道内部路由表
    ip route replace "$LOCALIP" dev "$DEV" scope link table "$TUNNEL_TABLE"
    ip route replace default via "$REMOTEIP" dev "$DEV" table "$TUNNEL_TABLE"
    echo "Policy rules added."
}

# 添加 iptables MASQUERADE
add_iptables() {
    echo "Adding iptables MASQUERADE..."
    iptables -t nat -A POSTROUTING -o "$DEV" -j MASQUERADE
}

# ----------------------------- 控制接口（start / stop / restart） ------------
start() {
    echo "Starting VPN and routing setup..."
    # 先清理，保证无残留
    clean_all
    # 获取物理网卡信息
    get_network_info || exit 1
    # 顺序启动
    start_tunnel
    add_routes
    add_policy_rules
    add_iptables
    echo "Start completed."
}

stop() {
    echo "Stopping VPN and cleaning up..."
    clean_all
    echo "Stop completed."
}

restart() {
    stop
    sleep 1
    start
}

# ----------------------------- 命令行入口 ------------------------------------
usage() {
    echo "Usage: $0 {start|stop|restart}"
    echo "  start   - Start VPN tunnel and configure routing"
    echo "  stop    - Stop VPN tunnel and remove all configurations"
    echo "  restart - Stop then Start"
    exit 1
}

case "$1" in
    start)   start ;;
    stop)    stop ;;
    restart) restart ;;
    *)       usage ;;
esac
