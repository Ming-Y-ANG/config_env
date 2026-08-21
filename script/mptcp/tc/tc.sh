#!/bin/sh
#
# 功能：为手动指定的网络接口分别模拟非对称的延迟、抖动、丢包和限速
# 用法：./tc.sh {start|stop|status|selftest}
# 配置：所有参数均在脚本开头的配置区修改

# ======================== 用户配置区 ========================

# 接口配置：使用分号分隔每个接口，格式：
#   接口名:上行参数|下行参数;接口名:上行参数|下行参数;...
# 上行/下行参数格式："延迟 抖动 丢包率 带宽速率"
# 若某方向不需要模拟，对应字段设为 "off"
# 示例：
#   INTERFACES="eth0:100ms 20ms 5% 1mbit|200ms 40ms 2% 5mbit;eth1:off off off 10mbit|80ms 15ms 0.5% 20mbit"
INTERFACES="enp3s0:off off off 1mbit|200ms 40ms 2% 5mbit"

# 是否启用入口（下行）模拟（需要 ifb 支持），设为 "false" 禁用
ENABLE_INGRESS="false"

# 限速器通用参数（一般无需改动）
BURST="32kbit"
LATENCY="400ms"

# 自测使用的临时接口名
TEST_IFACE="dummy0"

# 是否启用真实流量验证（需要 ip netns、iperf3、ping）
ENABLE_SELFTEST_TRAFFIC="false"

# 真实流量验证使用的网络命名空间与 veth 配置
TRAFFIC_NS_SERVER="tc_ns_server"
TRAFFIC_NS_CLIENT="tc_ns_client"
TRAFFIC_VETH0="veth0"
TRAFFIC_VETH1="veth1"
TRAFFIC_SUBNET="10.200.1"
TRAFFIC_SERVER_IP="${TRAFFIC_SUBNET}.1"
TRAFFIC_CLIENT_IP="${TRAFFIC_SUBNET}.2"

# 真实流量验证的 tc 参数
TRAFFIC_UP_RATE="10mbit"
TRAFFIC_UP_DELAY="50ms"
TRAFFIC_UP_JITTER="5ms"
TRAFFIC_UP_LOSS="2%"
TRAFFIC_DOWN_RATE="5mbit"
TRAFFIC_DOWN_DELAY="100ms"
TRAFFIC_DOWN_JITTER="10ms"
TRAFFIC_DOWN_LOSS="5%"

# 真实流量验证的测试参数与判定阈值
TRAFFIC_PING_COUNT=50
TRAFFIC_PING_INTERVAL=0.1
TRAFFIC_IPERF_TIME=5
TRAFFIC_RTT_MIN_MS=120
TRAFFIC_UP_MIN_MBIT=7.0
TRAFFIC_UP_MAX_MBIT=13.0
TRAFFIC_DOWN_MIN_MBIT=3.5
TRAFFIC_DOWN_MAX_MBIT=6.5

# ======================== 内部函数（无需修改） ========================

# 检查 root 权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "错误：此脚本需要 root 权限运行。请使用 sudo。" >&2
        exit 1
    fi
}

# 加载必要内核模块
load_modules() {
    if [ "$ENABLE_INGRESS" = "true" ]; then
        modprobe ifb 2>/dev/null || {
            echo "警告：无法加载 ifb 模块，将禁用入口模拟。" >&2
            ENABLE_INGRESS="false"
        }
    fi
}

# 初始化 IFB 设备
init_ifb() {
    OLD_IFS="$IFS"
    IFS=';'
    set -f
    for entry in $INTERFACES; do
        entry="$(printf '%s' "$entry" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -z "$entry" ] && continue
        iface="${entry%%:*}"
        [ "$iface" = "$entry" ] && continue
        ifb="ifb_${iface}"
        ip link show "$ifb" >/dev/null 2>&1 || ip link add "$ifb" type ifb
        ip link set dev "$ifb" up
    done
    IFS="$OLD_IFS"
    set +f
}

# 清除所有规则（停止模拟）
clean_all() {
    quiet="$1"
    OLD_IFS="$IFS"
    IFS=';'
    set -f
    for entry in $INTERFACES; do
        entry="$(printf '%s' "$entry" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -z "$entry" ] && continue
        iface="${entry%%:*}"
        [ "$iface" = "$entry" ] && continue

        # 删除物理接口上的规则
        tc qdisc del dev "$iface" root 2>/dev/null
        tc qdisc del dev "$iface" ingress 2>/dev/null
        tc filter del dev "$iface" parent ffff: 2>/dev/null

        # 删除对应的 ifb 设备
        ifb="ifb_${iface}"
        tc qdisc del dev "$ifb" root 2>/dev/null
        ip link set dev "$ifb" down 2>/dev/null
        ip link del "$ifb" 2>/dev/null
    done
    IFS="$OLD_IFS"
    set +f
    [ "$quiet" != "quiet" ] && echo "所有模拟规则已清除。"
}

# 解析条目，获取指定方向的参数
get_params() {
    entry="$1"
    direction="$2"   # "UP" 或 "DOWN"
    rest="${entry#*:}"
    up_params="${rest%%|*}"
    down_params="${rest#*|}"
    if [ "$direction" = "UP" ]; then
        printf '%s' "$up_params"
    else
        # 如果缺少 '|'，默认下行禁用
        if [ "$down_params" = "$rest" ]; then
            printf '%s' "off off off off"
        else
            printf '%s' "$down_params"
        fi
    fi
}

# 构建 netem 参数
build_netem_args() {
    delay="$1"
    jitter="$2"
    loss="$3"

    args=""
    [ -n "$delay" ] && args="${args}delay $delay"
    [ -n "$jitter" ] && [ "$jitter" != "0ms" ] && args="${args} $jitter"
    [ -n "$loss" ] && [ "$loss" != "0%" ] && args="${args} loss $loss"
    printf '%s' "$args" | sed 's/^ *//'
}

# 应用上行规则：先限速（tbf）后损伤（netem）
apply_up_rule() {
    iface="$1"
    params="$2"
    # 调用者可能把 IFS 设为 ';'，这里临时恢复为空格以按空格切分 4 个字段
    OLD_IFS="$IFS"
    IFS=' '
    set -- $params
    IFS="$OLD_IFS"
    if [ $# -ne 4 ]; then
        echo "错误：接口 $iface 上行参数必须是 '延迟 抖动 丢包率 带宽速率' 四个字段。" >&2
        return 1
    fi
    delay="$1"; jitter="$2"; loss="$3"; rate="$4"

    [ "$delay" = "off" ] && delay=""
    [ "$jitter" = "off" ] && jitter=""
    [ "$loss" = "off" ] && loss=""
    [ "$rate" = "off" ] && rate=""

    need_netem=false
    need_tbf=false
    [ -n "$delay" ] || [ -n "$jitter" ] || [ -n "$loss" ] && need_netem=true
    [ -n "$rate" ] && need_tbf=true

    if [ "$need_netem" = "false" ] && [ "$need_tbf" = "false" ]; then
        echo "接口 $iface 上行模拟已禁用。"
        return 0
    fi

    # netem 的抖动必须依附于 delay
    if [ -n "$jitter" ] && [ -z "$delay" ]; then
        echo "警告：接口 $iface 上行设置了抖动但未设置延迟，netem 无法单独设置抖动，已将抖动值作为延迟处理。" >&2
        delay="$jitter"
        jitter=""
    fi

    netem_args="$(build_netem_args "$delay" "$jitter" "$loss")"

    if [ "$need_tbf" = "true" ]; then
        tc qdisc add dev "$iface" root handle 1: tbf rate "$rate" burst "$BURST" latency "$LATENCY" >/dev/null 2>&1 || {
            echo "错误：无法为 $iface 添加 tbf 限速。" >&2
            return 1
        }
        if [ "$need_netem" = "true" ]; then
            tc qdisc add dev "$iface" parent 1:1 handle 10: netem $netem_args >/dev/null 2>&1 || {
                echo "错误：无法为 $iface 添加 netem 损伤。" >&2
                tc qdisc del dev "$iface" root 2>/dev/null
                return 1
            }
        fi
    else
        tc qdisc add dev "$iface" root handle 1: netem $netem_args >/dev/null 2>&1 || {
            echo "错误：无法为 $iface 添加 netem 根队列。" >&2
            return 1
        }
    fi

    printf '接口 %s 上行模拟：' "$iface"
    if [ "$need_netem" = "true" ]; then
        jitter_str=""
        [ -n "$jitter" ] && jitter_str=" ±${jitter}"
        delay_str="${delay:-off}"
        loss_str="${loss:-off}"
        printf '损伤=%s%s 丢包=%s' "$delay_str" "$jitter_str" "$loss_str"
    else
        printf '无损伤'
    fi
    if [ "$need_tbf" = "true" ]; then
        printf ' 限速=%s\n' "$rate"
    else
        printf ' 无限速\n'
    fi
    return 0
}

# 应用下行规则（IFB）：先损伤（netem）后限速（tbf）
apply_down_rule() {
    iface="$1"
    if [ "$ENABLE_INGRESS" != "true" ]; then
        echo "入口模拟未启用，跳过 $iface 下行配置。"
        return 0
    fi

    params="$2"
    # 调用者可能把 IFS 设为 ';'，这里临时恢复为空格以按空格切分 4 个字段
    OLD_IFS="$IFS"
    IFS=' '
    set -- $params
    IFS="$OLD_IFS"
    if [ $# -ne 4 ]; then
        echo "错误：接口 $iface 下行参数必须是 '延迟 抖动 丢包率 带宽速率' 四个字段。" >&2
        return 1
    fi
    delay="$1"; jitter="$2"; loss="$3"; rate="$4"

    [ "$delay" = "off" ] && delay=""
    [ "$jitter" = "off" ] && jitter=""
    [ "$loss" = "off" ] && loss=""
    [ "$rate" = "off" ] && rate=""

    need_netem=false
    need_tbf=false
    [ -n "$delay" ] || [ -n "$jitter" ] || [ -n "$loss" ] && need_netem=true
    [ -n "$rate" ] && need_tbf=true

    if [ "$need_netem" = "false" ] && [ "$need_tbf" = "false" ]; then
        echo "接口 $iface 下行模拟已禁用。"
        return 0
    fi

    if [ -n "$jitter" ] && [ -z "$delay" ]; then
        echo "警告：接口 $iface 下行设置了抖动但未设置延迟，已将抖动值作为延迟处理。" >&2
        delay="$jitter"
        jitter=""
    fi

    netem_args="$(build_netem_args "$delay" "$jitter" "$loss")"

    ifb="ifb_${iface}"
    ip link show "$ifb" >/dev/null 2>&1 || {
        echo "错误：ifb 设备 $ifb 不存在。" >&2
        return 1
    }

    # protocol all 同时捕获 IPv4 与 IPv6
    tc qdisc add dev "$iface" ingress >/dev/null 2>&1 || true
    tc filter add dev "$iface" parent ffff: protocol all u32 match u32 0 0 action mirred egress redirect dev "$ifb" >/dev/null 2>&1 || {
        echo "错误：无法为 $iface 添加入口重定向过滤器。" >&2
        return 1
    }

    if [ "$need_netem" = "true" ]; then
        tc qdisc add dev "$ifb" root handle 1: netem $netem_args >/dev/null 2>&1 || {
            echo "错误：无法为 $ifb 添加 netem 根队列。" >&2
            tc filter del dev "$iface" parent ffff: 2>/dev/null
            return 1
        }
        if [ "$need_tbf" = "true" ]; then
            tc qdisc add dev "$ifb" parent 1:1 handle 10: tbf rate "$rate" burst "$BURST" latency "$LATENCY" >/dev/null 2>&1 || {
                echo "错误：无法为 $ifb 添加 tbf 限速。" >&2
                tc qdisc del dev "$ifb" root 2>/dev/null
                tc filter del dev "$iface" parent ffff: 2>/dev/null
                return 1
            }
        fi
    else
        tc qdisc add dev "$ifb" root handle 1: tbf rate "$rate" burst "$BURST" latency "$LATENCY" >/dev/null 2>&1 || {
            echo "错误：无法为 $ifb 添加 tbf 限速。" >&2
            tc filter del dev "$iface" parent ffff: 2>/dev/null
            return 1
        }
    fi

    printf '接口 %s 下行模拟：' "$iface"
    if [ "$need_netem" = "true" ]; then
        jitter_str=""
        [ -n "$jitter" ] && jitter_str=" ±${jitter}"
        delay_str="${delay:-off}"
        loss_str="${loss:-off}"
        printf '损伤=%s%s 丢包=%s' "$delay_str" "$jitter_str" "$loss_str"
    else
        printf '无损伤'
    fi
    if [ "$need_tbf" = "true" ]; then
        printf ' 限速=%s\n' "$rate"
    else
        printf ' 无限速\n'
    fi
    return 0
}

# 启动模拟
start_simulation() {
    if [ -z "$(printf '%s' "$INTERFACES" | tr -d ' \t\n')" ]; then
        echo "错误：INTERFACES 为空，请在脚本开头配置。" >&2
        exit 1
    fi

    check_root
    clean_all quiet
    load_modules
    if [ "$ENABLE_INGRESS" = "true" ]; then
        init_ifb
    fi

    failed=0
    OLD_IFS="$IFS"
    IFS=';'
    set -f
    for entry in $INTERFACES; do
        entry="$(printf '%s' "$entry" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -z "$entry" ] && continue
        iface="${entry%%:*}"
        if [ "$iface" = "$entry" ]; then
            echo "警告：忽略无效条目（缺少冒号）: $entry" >&2
            continue
        fi

        ip link show "$iface" >/dev/null 2>&1 || {
            echo "警告：接口 $iface 不存在，跳过。" >&2
            continue
        }

        printf '处理接口 %s ...\n' "$iface"
        # 恢复默认 IFS：apply_* 函数内部需要按空格解析参数，
        # 且 netem_args 的展开也依赖默认 IFS 才能被 tc 正确识别。
        IFS="$OLD_IFS"
        up_params="$(get_params "$entry" "UP")"
        down_params="$(get_params "$entry" "DOWN")"
        apply_up_rule "$iface" "$up_params" || failed=$((failed + 1))
        apply_down_rule "$iface" "$down_params" || failed=$((failed + 1))
        IFS=';'
    done
    IFS="$OLD_IFS"
    set +f

    if [ "$failed" -gt 0 ]; then
        echo "警告：$failed 个规则应用失败，请检查上面的错误信息。" >&2
        return 1
    fi
    echo "所有模拟规则已应用。"
}

# 停止模拟
stop_simulation() {
    check_root
    clean_all
}

# 显示状态
status_simulation() {
    echo "==================== 当前模拟状态 ===================="
    OLD_IFS="$IFS"
    IFS=';'
    set -f
    for entry in $INTERFACES; do
        entry="$(printf '%s' "$entry" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -z "$entry" ] && continue
        iface="${entry%%:*}"
        [ "$iface" = "$entry" ] && continue

        up_params="$(get_params "$entry" "UP")"
        down_params="$(get_params "$entry" "DOWN")"

        echo ""
        echo "【接口 $iface】"
        echo "  上行配置: $up_params"
        echo "  下行配置: $down_params"

        if ! ip link show "$iface" >/dev/null 2>&1; then
            echo "  警告：接口 $iface 不存在"
            continue
        fi

        echo "  ---- 上行队列 (root on $iface) ----"
        tc qdisc show dev "$iface" | sed 's/^/    /'

        if [ "$ENABLE_INGRESS" = "true" ]; then
            ifb="ifb_${iface}"
            if ip link show "$ifb" >/dev/null 2>&1; then
                echo "  ---- 下行队列 (on $ifb) ----"
                tc qdisc show dev "$ifb" | sed 's/^/    /'
                echo "  ---- 下行过滤器 (on $iface) ----"
                tc filter show dev "$iface" parent ffff: | sed 's/^/    /'
            else
                echo "  ---- 下行队列：ifb 设备 $ifb 未创建 ----"
            fi
        else
            echo "  ---- 下行模拟未启用 ----"
        fi
    done
    IFS="$OLD_IFS"
    set +f
    echo "======================================================="
}

# ======================== 自测函数 ========================

# 自测断言：检查某个 qdisc 是否存在
_assert_qdisc() {
    dev="$1"
    pattern="$2"
    desc="$3"
    actual=$(tc qdisc show dev "$dev" 2>&1)
    if printf '%s' "$actual" | grep -q "$pattern"; then
        echo "  [PASS] $desc"
        return 0
    else
        echo "  [FAIL] $desc" >&2
        echo "  [DIAG] 当前 $dev 的 qdisc 状态：" >&2
        printf '%s\n' "$actual" | sed 's/^/    /' >&2
        echo "  [HINT] 手动排查命令：tc qdisc show dev $dev" >&2
        return 1
    fi
}

# 自测断言：检查入口重定向过滤器是否存在且目标正确
_assert_filter_redirect() {
    dev="$1"
    target="$2"
    actual=$(tc filter show dev "$dev" parent ffff: 2>&1)
    if printf '%s' "$actual" | grep -q "Redirect to device ${target}"; then
        echo "  [PASS] $dev 入口重定向到 $target"
        return 0
    else
        echo "  [FAIL] $dev 入口重定向未找到" >&2
        echo "  [DIAG] 当前 $dev 的 ingress filter 状态：" >&2
        printf '%s\n' "$actual" | sed 's/^/    /' >&2
        echo "  [HINT] 手动排查命令：tc filter show dev $dev parent ffff:" >&2
        echo "  [HINT] 常见原因：ingress qdisc 未添加、ifb 设备未创建、或过滤器协议不匹配" >&2
        return 1
    fi
}

# 自测断言：检查接口不存在（已清理）
_assert_iface_gone() {
    dev="$1"
    if ip link show "$dev" >/dev/null 2>&1; then
        echo "  [FAIL] $dev 仍然存在" >&2
        echo "  [DIAG] $dev 仍然可见：" >&2
        ip link show "$dev" 2>&1 | sed 's/^/    /' >&2
        echo "  [HINT] 手动清理命令：ip link del $dev" >&2
        return 1
    else
        echo "  [PASS] $dev 已清理"
        return 0
    fi
}

# 打印排查建议
print_troubleshooting() {
    echo "" >&2
    echo "==================== 排查建议 ====================" >&2
    echo "1. 确认以 root 权限运行：sudo ./tc.sh selftest" >&2
    echo "2. 确认 ifb 模块已加载：modprobe ifb" >&2
    echo "3. 查看目标接口是否存在：ip link show <iface>" >&2
    echo "4. 查看 tc 队列规则：tc qdisc show dev <iface>" >&2
    echo "5. 查看入口重定向过滤器：tc filter show dev <iface> parent ffff:" >&2
    echo "6. 流量测试失败时，确认 iperf3 已安装：command -v iperf3" >&2
    echo "7. 确认系统支持 network namespace：ip netns list" >&2
    echo "8. 查看详细 tc 统计：tc -s qdisc show dev <iface>" >&2
    echo "==================================================" >&2
}

# 创建/清理自测用的 dummy 接口
create_test_iface() {
    ip link add "$TEST_IFACE" type dummy 2>/dev/null || true
    ip link set "$TEST_IFACE" up
}

remove_test_iface() {
    ip link del "$TEST_IFACE" 2>/dev/null || true
    ip link del "ifb_${TEST_IFACE}" 2>/dev/null || true
}

# ======================== 真实流量验证函数 ========================

create_traffic_test_env() {
    ip netns add "$TRAFFIC_NS_SERVER" 2>/dev/null || true
    ip netns add "$TRAFFIC_NS_CLIENT" 2>/dev/null || true

    # 创建 veth pair，两端分别移入 server/client namespace
    ip link del "$TRAFFIC_VETH0" 2>/dev/null || true
    ip link add "$TRAFFIC_VETH0" type veth peer name "$TRAFFIC_VETH1"
    ip link set "$TRAFFIC_VETH0" netns "$TRAFFIC_NS_SERVER"
    ip link set "$TRAFFIC_VETH1" netns "$TRAFFIC_NS_CLIENT"

    # 配置 server 端
    ip netns exec "$TRAFFIC_NS_SERVER" ip link set lo up
    ip netns exec "$TRAFFIC_NS_SERVER" ip link set "$TRAFFIC_VETH0" up
    ip netns exec "$TRAFFIC_NS_SERVER" ip addr add "$TRAFFIC_SERVER_IP/24" dev "$TRAFFIC_VETH0"

    # 配置 client 端
    ip netns exec "$TRAFFIC_NS_CLIENT" ip link set lo up
    ip netns exec "$TRAFFIC_NS_CLIENT" ip link set "$TRAFFIC_VETH1" up
    ip netns exec "$TRAFFIC_NS_CLIENT" ip addr add "$TRAFFIC_CLIENT_IP/24" dev "$TRAFFIC_VETH1"
}

remove_traffic_test_env() {
    ip netns del "$TRAFFIC_NS_SERVER" 2>/dev/null || true
    ip netns del "$TRAFFIC_NS_CLIENT" 2>/dev/null || true
    rm -f /tmp/tc_iperf3_server.pid
}

apply_traffic_tc_rules() {
    ns="$TRAFFIC_NS_CLIENT"
    iface="$TRAFFIC_VETH1"
    ifb="ifb_${iface}"

    # 上行（client 出口）：tbf root -> netem child
    ip netns exec "$ns" tc qdisc add dev "$iface" root handle 1: \
        tbf rate "$TRAFFIC_UP_RATE" burst "$BURST" latency "$LATENCY"
    ip netns exec "$ns" tc qdisc add dev "$iface" parent 1:1 handle 10: \
        netem delay "$TRAFFIC_UP_DELAY" "$TRAFFIC_UP_JITTER" loss "$TRAFFIC_UP_LOSS"

    # 下行（client 入口）：重定向到 IFB，netem root -> tbf child
    ip netns exec "$ns" ip link add "$ifb" type ifb 2>/dev/null || true
    ip netns exec "$ns" ip link set "$ifb" up
    ip netns exec "$ns" tc qdisc add dev "$iface" ingress
    ip netns exec "$ns" tc filter add dev "$iface" parent ffff: protocol all \
        u32 match u32 0 0 action mirred egress redirect dev "$ifb"
    ip netns exec "$ns" tc qdisc add dev "$ifb" root handle 1: \
        netem delay "$TRAFFIC_DOWN_DELAY" "$TRAFFIC_DOWN_JITTER" loss "$TRAFFIC_DOWN_LOSS"
    ip netns exec "$ns" tc qdisc add dev "$ifb" parent 1:1 handle 10: \
        tbf rate "$TRAFFIC_DOWN_RATE" burst "$BURST" latency "$LATENCY"
}

cleanup_traffic_tc_rules() {
    ns="$TRAFFIC_NS_CLIENT"
    iface="$TRAFFIC_VETH1"
    ifb="ifb_${iface}"
    ip netns exec "$ns" tc qdisc del dev "$iface" root 2>/dev/null || true
    ip netns exec "$ns" tc qdisc del dev "$iface" ingress 2>/dev/null || true
    ip netns exec "$ns" tc filter del dev "$iface" parent ffff: 2>/dev/null || true
    ip netns exec "$ns" tc qdisc del dev "$ifb" root 2>/dev/null || true
    ip netns exec "$ns" ip link set "$ifb" down 2>/dev/null || true
    ip netns exec "$ns" ip link del "$ifb" 2>/dev/null || true
}

run_ping_test() {
    echo "  ---- 运行 ping 测试（验证延迟与丢包）----"
    output=$(ip netns exec "$TRAFFIC_NS_CLIENT" \
        ping -c "$TRAFFIC_PING_COUNT" -i "$TRAFFIC_PING_INTERVAL" "$TRAFFIC_SERVER_IP" 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "  [FAIL] ping 命令失败，输出如下：" >&2
        printf '%s\n' "$output" | sed 's/^/    /' >&2
        echo "  [HINT] 先确认基础连通性：ip netns exec $TRAFFIC_NS_CLIENT ping -c 3 $TRAFFIC_SERVER_IP" >&2
        return 1
    fi

    # 解析丢包率与平均 RTT
    loss=$(printf '%s' "$output" | grep -o '[0-9]*%' | head -1 | tr -d '%')
    loss=${loss:-0}
    avg_rtt=$(printf '%s' "$output" | awk -F'[=/ ]+' '/rtt min/ {print $7}')

    echo "  平均 RTT: ${avg_rtt}ms, 丢包率: ${loss}%"

    local_fail=0
    if [ -n "$avg_rtt" ] && awk "BEGIN {exit !($avg_rtt >= $TRAFFIC_RTT_MIN_MS)}"; then
        echo "  [PASS] 平均 RTT ${avg_rtt}ms 符合预期（>= ${TRAFFIC_RTT_MIN_MS}ms）"
    else
        echo "  [FAIL] 平均 RTT ${avg_rtt}ms 低于预期（应 >= ${TRAFFIC_RTT_MIN_MS}ms）" >&2
        echo "  [DIAG] 当前 client 端 tc 规则：" >&2
        ip netns exec "$TRAFFIC_NS_CLIENT" tc qdisc show dev "$TRAFFIC_VETH1" 2>&1 | sed 's/^/    /' >&2
        echo "  [HINT] 可能原因：netem 规则未生效、tc 链顺序错误、或测试阈值不适合当前内核" >&2
        local_fail=1
    fi

    if [ "$loss" -gt 0 ]; then
        echo "  [PASS] 检测到丢包（${loss}%），netem 生效"
    else
        echo "  [FAIL] 未检测到丢包，netem 可能未生效" >&2
        echo "  [HINT] 可增大 TRAFFIC_PING_COUNT 再试，或检查 tc filter 是否匹配到流量" >&2
        local_fail=1
    fi

    return "$local_fail"
}

_stop_iperf3_server() {
    if [ -f /tmp/tc_iperf3_server.pid ]; then
        kill "$(cat /tmp/tc_iperf3_server.pid)" 2>/dev/null || true
        rm -f /tmp/tc_iperf3_server.pid
    fi
    # 兜底：直接杀掉 namespace 内的 iperf3
    ip netns exec "$TRAFFIC_NS_SERVER" pkill -x iperf3 2>/dev/null || true
}

_start_iperf3_server() {
    _stop_iperf3_server
    rm -f /tmp/tc_iperf3_server.pid
    ip netns exec "$TRAFFIC_NS_SERVER" iperf3 -s -D -I /tmp/tc_iperf3_server.pid >/dev/null 2>&1
    sleep 1
}

_restart_iperf3_server() {
    _stop_iperf3_server
    _start_iperf3_server
}

run_iperf3_test() {
    echo "  ---- 运行 iperf3 测试（验证带宽）----"
    if ! command -v iperf3 >/dev/null 2>&1; then
        echo "  [SKIP] 未找到 iperf3，跳过带宽测试"
        echo "  [HINT] 安装 iperf3：apt-get install iperf3 / yum install iperf3"
        return 0
    fi

    # 在 server namespace 后台启动 iperf3 server
    rm -f /tmp/tc_iperf3_server.pid
    ip netns exec "$TRAFFIC_NS_SERVER" iperf3 -s -D -I /tmp/tc_iperf3_server.pid >/dev/null 2>&1
    sleep 1

    # 确认 server 已启动
    if ! ip netns exec "$TRAFFIC_NS_SERVER" pgrep -x iperf3 >/dev/null 2>&1; then
        echo "  [FAIL] iperf3 server 启动失败" >&2
        echo "  [HINT] 手动检查：ip netns exec $TRAFFIC_NS_SERVER iperf3 -s" >&2
        return 1
    fi

    local_fail=0

    # 上传测试（client -> server，对应 client veth1 出口）
    echo "  测试上传带宽（限速 ${TRAFFIC_UP_RATE}）..."
    up_output=$(ip netns exec "$TRAFFIC_NS_CLIENT" \
        iperf3 -c "$TRAFFIC_SERVER_IP" -t "$TRAFFIC_IPERF_TIME" -f m -u -b 20M 2>&1)
    up_rate=$(printf '%s' "$up_output" | grep 'receiver' | grep -o '[0-9.]* Mbits/sec' | head -1 | awk '{print $1}')
    echo "  上传带宽: ${up_rate} Mbits/sec"
    if [ -n "$up_rate" ] && awk "BEGIN {exit !($up_rate >= $TRAFFIC_UP_MIN_MBIT && $up_rate <= $TRAFFIC_UP_MAX_MBIT)}"; then
        echo "  [PASS] 上传带宽符合预期"
    else
        echo "  [FAIL] 上传带宽不符合预期（应在 ${TRAFFIC_UP_MIN_MBIT}~${TRAFFIC_UP_MAX_MBIT} Mbits/sec 之间）" >&2
        echo "  [DIAG] iperf3 上传测试原始输出：" >&2
        printf '%s\n' "$up_output" | sed 's/^/    /' >&2
        echo "  [DIAG] 当前 client 端 tc 规则：" >&2
        ip netns exec "$TRAFFIC_NS_CLIENT" tc qdisc show dev "$TRAFFIC_VETH1" 2>&1 | sed 's/^/    /' >&2
        echo "  [HINT] 可能原因：tbf burst 太小、tc 链顺序错误、或 netem 丢包导致 UDP 有效带宽下降" >&2
        local_fail=1
    fi

    # 上传测完后重启 server，避免 server busy
    _restart_iperf3_server

    # 下载测试（server -> client，对应 client veth1 入口）
    echo "  测试下载带宽（限速 ${TRAFFIC_DOWN_RATE}）..."
    down_output=$(ip netns exec "$TRAFFIC_NS_CLIENT" \
        iperf3 -c "$TRAFFIC_SERVER_IP" -t "$TRAFFIC_IPERF_TIME" -f m -u -b 20M -R 2>&1)
    down_rate=$(printf '%s' "$down_output" | grep 'receiver' | grep -o '[0-9.]* Mbits/sec' | head -1 | awk '{print $1}')
    echo "  下载带宽: ${down_rate} Mbits/sec"
    if [ -n "$down_rate" ] && awk "BEGIN {exit !($down_rate >= $TRAFFIC_DOWN_MIN_MBIT && $down_rate <= $TRAFFIC_DOWN_MAX_MBIT)}"; then
        echo "  [PASS] 下载带宽符合预期"
    else
        echo "  [FAIL] 下载带宽不符合预期（应在 ${TRAFFIC_DOWN_MIN_MBIT}~${TRAFFIC_DOWN_MAX_MBIT} Mbits/sec 之间）" >&2
        echo "  [DIAG] iperf3 下载测试原始输出：" >&2
        printf '%s\n' "$down_output" | sed 's/^/    /' >&2
        echo "  [DIAG] 当前 client 端 ingress / ifb 规则：" >&2
        ip netns exec "$TRAFFIC_NS_CLIENT" tc qdisc show dev "$TRAFFIC_VETH1" 2>&1 | sed 's/^/    /' >&2
        ip netns exec "$TRAFFIC_NS_CLIENT" tc qdisc show dev "ifb_${TRAFFIC_VETH1}" 2>&1 | sed 's/^/    /' >&2
        echo "  [HINT] 可能原因：ifb 设备未创建、ingress filter 未匹配、或 tbf 参数不合适" >&2
        local_fail=1
    fi

    # 停止 iperf3 server
    if [ -f /tmp/tc_iperf3_server.pid ]; then
        kill "$(cat /tmp/tc_iperf3_server.pid)" 2>/dev/null || true
        rm -f /tmp/tc_iperf3_server.pid
    fi

    return "$local_fail"
}

traffic_selftest() {
    echo ""
    echo "---- 真实流量验证（veth + network namespace）----"

    # 检查前置条件
    if ! ip netns list >/dev/null 2>&1; then
        echo "  [SKIP] 当前系统不支持 network namespace，跳过流量验证"
        return 0
    fi
    if ! command -v ping >/dev/null 2>&1; then
        echo "  [SKIP] 未找到 ping，跳过流量验证"
        return 0
    fi

    # 确保 ifb 模块已加载
    modprobe ifb 2>/dev/null || true

    local_fail=0

    create_traffic_test_env
    apply_traffic_tc_rules

    # 等待接口就绪
    sleep 1

    # 基础连通性检查
    if ! ip netns exec "$TRAFFIC_NS_CLIENT" ping -c 1 -W 2 "$TRAFFIC_SERVER_IP" >/dev/null 2>&1; then
        echo "  [FAIL] 基础连通性检查失败" >&2
        echo "  [DIAG] client namespace 接口状态：" >&2
        ip netns exec "$TRAFFIC_NS_CLIENT" ip addr show 2>&1 | sed 's/^/    /' >&2
        echo "  [DIAG] server namespace 接口状态：" >&2
        ip netns exec "$TRAFFIC_NS_SERVER" ip addr show 2>&1 | sed 's/^/    /' >&2
        echo "  [HINT] 手动排查：ip netns exec $TRAFFIC_NS_CLIENT ping -c 3 $TRAFFIC_SERVER_IP" >&2
        cleanup_traffic_tc_rules
        remove_traffic_test_env
        return 1
    fi
    echo "  [PASS] 基础连通性正常"

    run_ping_test || local_fail=1
    run_iperf3_test || local_fail=1

    cleanup_traffic_tc_rules
    remove_traffic_test_env

    if [ "$local_fail" -eq 0 ]; then
        echo "  流量验证全部通过。"
    else
        echo "  流量验证存在失败项。" >&2
    fi

    return "$local_fail"
}

# 自测入口
selftest_simulation() {
    check_root

    # 保存用户原始配置
    orig_interfaces="$INTERFACES"
    orig_enable_ingress="$ENABLE_INGRESS"

    # 确保测试结束后恢复并清理
    _cleanup_selftest() {
        INTERFACES="$orig_interfaces"
        ENABLE_INGRESS="$orig_enable_ingress"
        remove_test_iface
        remove_traffic_test_env
    }
    trap _cleanup_selftest EXIT

    create_test_iface

    total_fail=0

    echo "==================== 自测开始 ===================="

    # ---- 测试 1：上行仅限速 ----
    echo ""
    echo "---- 测试 1：上行仅限速（tbf 作为根队列）----"
    INTERFACES="${TEST_IFACE}:off off off 1mbit|off off off off"
    ENABLE_INGRESS="false"
    start_simulation
    _assert_qdisc "$TEST_IFACE" "qdisc tbf 1: root" "上行根队列为 tbf" || total_fail=$((total_fail + 1))
    _assert_qdisc "$TEST_IFACE" "rate 1Mbit" "上行限速为 1mbit" || total_fail=$((total_fail + 1))
    if tc qdisc show dev "$TEST_IFACE" 2>/dev/null | grep -q "qdisc netem"; then
        echo "  [FAIL] 上行不应存在 netem" >&2
        echo "  [DIAG] 当前 $TEST_IFACE 的 qdisc：" >&2
        tc qdisc show dev "$TEST_IFACE" 2>&1 | sed 's/^/    /' >&2
        echo "  [HINT] 可能原因：apply_up_rule 中 need_netem 判断错误，或之前测试未清理" >&2
        total_fail=$((total_fail + 1))
    else
        echo "  [PASS] 上行无 netem"
    fi

    # ---- 测试 2：上行损伤 + 限速 ----
    echo ""
    echo "---- 测试 2：上行损伤 + 限速（tbf -> netem）----"
    INTERFACES="${TEST_IFACE}:100ms 20ms 5% 1mbit|off off off off"
    ENABLE_INGRESS="false"
    start_simulation
    _assert_qdisc "$TEST_IFACE" "qdisc tbf 1: root" "上行根队列为 tbf（限速在前）" || total_fail=$((total_fail + 1))
    _assert_qdisc "$TEST_IFACE" "qdisc netem 10: parent 1:1" "上行 netem 挂在 tbf 下（损伤在后）" || total_fail=$((total_fail + 1))
    _assert_qdisc "$TEST_IFACE" "delay 100ms.*20ms" "上行延迟/抖动正确" || total_fail=$((total_fail + 1))
    _assert_qdisc "$TEST_IFACE" "loss 5%" "上行丢包率正确" || total_fail=$((total_fail + 1))

    # ---- 测试 3：抖动单独设置容错 ----
    echo ""
    echo "---- 测试 3：delay=off 但 jitter 非 off 时自动降级 ----"
    INTERFACES="${TEST_IFACE}:off 20ms off 1mbit|off off off off"
    ENABLE_INGRESS="false"
    start_simulation
    _assert_qdisc "$TEST_IFACE" "qdisc tbf 1: root" "上行根队列为 tbf" || total_fail=$((total_fail + 1))
    _assert_qdisc "$TEST_IFACE" "qdisc netem 10: parent 1:1" "上行 netem 存在" || total_fail=$((total_fail + 1))
    _assert_qdisc "$TEST_IFACE" "delay 20ms" "jitter 已作为 delay 生效" || total_fail=$((total_fail + 1))

    # ---- 测试 4：下行 IFB 损伤 + 限速 ----
    echo ""
    echo "---- 测试 4：下行损伤 + 限速（IFB：netem -> tbf）----"
    INTERFACES="${TEST_IFACE}:off off off off|200ms 40ms 2% 5mbit"
    ENABLE_INGRESS="true"
    start_simulation
    _assert_qdisc "$TEST_IFACE" "qdisc ingress" "物理接口已添加 ingress qdisc" || total_fail=$((total_fail + 1))
    _assert_filter_redirect "$TEST_IFACE" "ifb_${TEST_IFACE}" "入口重定向到 ifb_${TEST_IFACE}" || total_fail=$((total_fail + 1))
    _assert_qdisc "ifb_${TEST_IFACE}" "qdisc netem 1: root" "ifb 根队列为 netem（损伤在前）" || total_fail=$((total_fail + 1))
    _assert_qdisc "ifb_${TEST_IFACE}" "qdisc tbf 10: parent 1:1" "ifb tbf 挂在 netem 下（限速在后）" || total_fail=$((total_fail + 1))
    _assert_qdisc "ifb_${TEST_IFACE}" "rate 5Mbit" "下行限速为 5mbit" || total_fail=$((total_fail + 1))

    # ---- 测试 5：连续 start 无需 stop ----
    echo ""
    echo "---- 测试 5：连续执行 start 不应失败 ----"
    INTERFACES="${TEST_IFACE}:off off off 1mbit|off off off off"
    ENABLE_INGRESS="false"
    if start_simulation; then
        echo "  [PASS] 第一次 start 成功"
    else
        echo "  [FAIL] 第一次 start 失败" >&2
        total_fail=$((total_fail + 1))
    fi
    if start_simulation; then
        echo "  [PASS] 第二次 start（无 stop）成功"
    else
        echo "  [FAIL] 第二次 start（无 stop）失败" >&2
        total_fail=$((total_fail + 1))
    fi

    # ---- 测试 6：stop 清理 ----
    echo ""
    echo "---- 测试 6：stop 后所有规则已清理 ----"
    stop_simulation
    if tc qdisc show dev "$TEST_IFACE" 2>/dev/null | grep -v "qdisc noqueue" | grep -q "qdisc"; then
        echo "  [FAIL] $TEST_IFACE 上仍有 qdisc" >&2
        echo "  [DIAG] 当前 $TEST_IFACE 的 qdisc：" >&2
        tc qdisc show dev "$TEST_IFACE" 2>&1 | sed 's/^/    /' >&2
        echo "  [HINT] 手动清理：tc qdisc del dev $TEST_IFACE root; tc qdisc del dev $TEST_IFACE ingress" >&2
        total_fail=$((total_fail + 1))
    else
        echo "  [PASS] $TEST_IFACE 上无残留 qdisc"
    fi
    _assert_iface_gone "ifb_${TEST_IFACE}" || total_fail=$((total_fail + 1))

    # ---- 测试 7：真实流量验证（可选） ----
    if [ "$ENABLE_SELFTEST_TRAFFIC" = "true" ]; then
        traffic_selftest || total_fail=$((total_fail + 1))
    else
        echo ""
        echo "---- 真实流量验证已跳过（ENABLE_SELFTEST_TRAFFIC=false）----"
    fi

    echo ""
    echo "==================== 自测结束 ===================="
    if [ "$total_fail" -gt 0 ]; then
        echo "结果：$total_fail 项测试失败。" >&2
        print_troubleshooting
        return 1
    fi
    echo "结果：全部通过。"
    return 0
}

# ======================== 主入口 ========================

case "$1" in
    start)
        start_simulation
        ;;
    stop)
        stop_simulation
        ;;
    status)
        status_simulation
        ;;
    selftest)
        selftest_simulation
        ;;
    *)
        echo "用法: $0 {start|stop|status|selftest}"
        echo ""
        echo "配置请修改脚本开头的 INTERFACES 变量，格式："
        echo '  INTERFACES="接口名:上行参数|下行参数;接口名:上行参数|下行参数;..."'
        echo '  上行/下行参数格式："延迟 抖动 丢包率 带宽速率"'
        echo '  示例：'
        echo '  INTERFACES="eth0:100ms 20ms 5% 1mbit|200ms 40ms 2% 5mbit"'
        exit 1
        ;;
esac

exit 0
