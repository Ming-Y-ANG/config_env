#!/bin/sh
# =============================================================================
# 策略路由配置脚本（多网络出口）
# 功能：根据源IP地址选择不同路由表，实现双网卡分流
# 用法：$0 {start|stop|restart}
# =============================================================================

# ----------------------------- 静态配置（可按需修改） -------------------------
DEV1="apn01"
DEV2="apn11"
PRIORITY1=150
PRIORITY2=151
TABLE1=200
TABLE2=201

# ----------------------------- 全局变量（动态获取） ---------------------------
DEV1_IP=""
DEV1_GW=""
DEV2_IP=""
DEV2_GW=""

# ----------------------------- 工具函数（获取网络信息） -----------------------
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
    DEV1_IP=$(ip -4 addr show dev "$DEV1" | grep -w inet | head -1 | awk '{print $2}' | cut -d'/' -f1)
    DEV2_IP=$(ip -4 addr show dev "$DEV2" | grep -w inet | head -1 | awk '{print $2}' | cut -d'/' -f1)

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

# ----------------------------- MPTCP endpoint 管理 ----------------------------
# 检查内核是否支持 MPTCP
check_mptcp_support() {
    if ! command -v ip mptcp >/dev/null 2>&1; then
        echo "WARN: 'ip mptcp' not supported, skipping MPTCP endpoint configuration." >&2
        return 1
    fi
    return 0
}

# 添加 MPTCP 子流端点（为每个物理网卡添加 subflow）
add_mptcp_endpoints() {
    if ! check_mptcp_support; then
        return 0
    fi

    echo "Adding MPTCP endpoints for $DEV1 and $DEV2..."
    # 先删除可能已经存在的（避免重复），但删除需要 id 或全部清空，此处采用先 flush 再添加（注意：flush 会删除所有端点）
    # 为了安全，我们只删除我们明确添加的设备相关的端点（较麻烦），使用 flush 可能会导致其他服务受影响。
    # 这里采取更保守的方法：只尝试添加，如果已存在则忽略错误
    ip mptcp endpoint add "$DEV1_IP" dev "$DEV1" id 1 subflow fullmesh 2>/dev/null || echo "  - $DEV1 endpoint already exists or failed"
    ip mptcp endpoint add "$DEV2_IP" dev "$DEV2" id 2 subflow fullmesh 2>/dev/null || echo "  - $DEV2 endpoint already exists or failed"
    echo "MPTCP endpoints added."
}

# 删除 MPTCP 端点（清空所有端点，谨慎使用）
remove_mptcp_endpoints() {
    if ! check_mptcp_support; then
        return 0
    fi

    echo "Removing MPTCP endpoints (flushing all)..."
    # 警告：flush 会删除所有已添加的端点，包括其他程序添加的
    #ip mptcp endpoint flush 2>/dev/null
    ip mptcp endpoint delete id 1 2>/dev/null || true
    ip mptcp endpoint delete id 2 2>/dev/null || true
    echo "MPTCP endpoints flushed."
}

# ----------------------------- 核心功能函数（添加 / 删除） --------------------
# 添加单个接口的策略路由（内部会先清理该接口的旧规则，保证幂等）
add_rules_for_interface() {
    local dev="$1"
    local ip="$2"
    local gw="$3"
    local table="$4"
    local priority="$5"

    # 如果IP或GW为空，跳过
    [ -z "$ip" ] && { echo "WARN: IP for $dev is empty, skipping."; return 1; }
    [ -z "$gw" ] && { echo "WARN: GW for $dev is empty, skipping."; return 1; }

    # 先删除该接口已有的规则（避免重复/冲突）
    ip rule del from "$ip" table "$table" priority "$priority" 2>/dev/null || true

    # 添加策略规则
    ip rule add from "$ip" table "$table" priority "$priority"
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to add rule for $dev (ip $ip)" >&2
        return 1
    fi

    # 配置该路由表的路由条目（先清空旧路由）
    ip route flush table "$table" 2>/dev/null || true
    ip route add "$ip" dev "$dev" scope link table "$table"
    ip route add default via "$gw" dev "$dev" table "$table"

    echo "OK: Rules for $dev (table $table) added."
    return 0
}

# 删除单个接口的策略路由（仅删除规则并清空路由表）
remove_rules_for_interface() {
    local dev="$1"
    local ip="$2"
    local table="$3"
    local priority="$4"

    [ -z "$ip" ] && { echo "WARN: IP for $dev unknown, cannot delete rule."; return 1; }

    ip rule del from "$ip" table "$table" priority "$priority" 2>/dev/null || true
    ip route flush table "$table" 2>/dev/null || true
    echo "OK: Rules for $dev (table $table) removed."
    return 0
}

# ----------------------------- 控制接口（start / stop / restart） ------------
start() {
    echo "Starting policy routing..."
    get_network_info || exit 1

    add_rules_for_interface "$DEV1" "$DEV1_IP" "$DEV1_GW" "$TABLE1" "$PRIORITY1"
    add_rules_for_interface "$DEV2" "$DEV2_IP" "$DEV2_GW" "$TABLE2" "$PRIORITY2"
    echo "Policy routing started successfully."
    add_mptcp_endpoints 
}

stop() {
    echo "Stopping policy routing..."
    # 需要先获取IP，否则无法删除（因为删除规则需要源IP作为匹配条件）
    # 但如果网络接口已down，可以尝试从缓存的变量中取，若无则跳过删除
    get_network_info 2>/dev/null || {
        echo "WARN: Could not fetch IPs, attempting to delete by table only (may fail)."
        # 直接按表删除规则（不指定from，可能删除所有使用该表的规则，但我们假设只有这两个规则）
        # 更稳妥：尝试删除任何包含该表的规则
        ip rule del table "$TABLE1" 2>/dev/null || true
        ip rule del table "$TABLE2" 2>/dev/null || true
        ip route flush table "$TABLE1" 2>/dev/null || true
        ip route flush table "$TABLE2" 2>/dev/null || true
        echo "Stop done (by table only)."
        return 0
    }

    remove_rules_for_interface "$DEV1" "$DEV1_IP" "$TABLE1" "$PRIORITY1"
    remove_rules_for_interface "$DEV2" "$DEV2_IP" "$TABLE2" "$PRIORITY2"
    echo "Policy routing stopped."
    remove_mptcp_endpoints
}

restart() {
    stop
    start
}

# ----------------------------- 命令行入口 ------------------------------------
usage() {
    echo "Usage: $0 {start|stop|restart}"
    echo "  start   - Add routing rules and populate tables"
    echo "  stop    - Remove routing rules and flush tables"
    echo "  restart - Stop then Start"
    exit 1
}

case "$1" in
    start)   start ;;
    stop)    stop ;;
    restart) restart ;;
    *)       usage ;;
esac

