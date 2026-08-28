#!/bin/sh
# tm.sh —— 多网卡实时流量监控（POSIX sh，类 top，默认 1s 刷新）
#
# 用法:
#   sh tm.sh                 # 监控所有网卡
#   sh tm.sh eth0 eth1       # 只监控指定网卡
#   sh tm.sh -i 2            # 刷新间隔改为 2 秒
#   sh tm.sh -i 2 eth0 eth1  # 组合使用
#
# 数据来源: /proc/net/dev (Linux)。按 Ctrl+C 退出。

INTERVAL=1

# ---- 解析参数 ----
while [ $# -gt 0 ]; do
    case "$1" in
        -i) INTERVAL=$2; shift 2 ;;
        -h|--help)
            sed -n '2,12p' "$0"; exit 0 ;;
        *)  break ;;
    esac
done
IFACES="$*"   # 为空表示监控全部

case "$INTERVAL" in
    ''|*[!0-9.]*) echo "错误: 刷新间隔必须是数字" >&2; exit 1 ;;
esac

[ -r /proc/net/dev ] || { echo "错误: 找不到 /proc/net/dev（仅支持 Linux）" >&2; exit 1; }

PREV="/tmp/.nettop.prev.$$"
CUR="/tmp/.nettop.cur.$$"

cleanup() {
    rm -f "$PREV" "$CUR"
    printf '\033[?25h\033[0m\n'   # 恢复光标和颜色
    exit 0
}
trap cleanup INT TERM

printf '\033[?25l'                # 隐藏光标

# 把字节/秒换算成可读单位
human() {
    awk -v b="$1" 'BEGIN{
        split("B/s|KB/s|MB/s|GB/s|TB/s", u, "|")
        i=1; while (b>=1024 && i<5) { b/=1024; i++ }
        printf "%7.1f %s", b, u[i]
    }'
}
# 累计字节数换算（去掉 /s）
humanB() {
    awk -v b="$1" 'BEGIN{
        split("B|KB|MB|GB|TB", u, "|")
        i=1; while (b>=1024 && i<5) { b/=1024; i++ }
        printf "%7.1f %s", b, u[i]
    }'
}

# 从 /proc/net/dev 抓 "网卡名 接收字节 发送字节"
snapshot() {
    # 默认空白分隔: $1="lo:" 去冒号后是网卡名, $2=接收字节, $10=发送字节
    awk 'NR>2 && NF>10 { sub(/:/, "", $1); print $1, $2, $10 }' /proc/net/dev
}

snapshot > "$PREV"
PTIME=$(date +%s%N 2>/dev/null || date +%s)

while :; do
    sleep "$INTERVAL"
    snapshot > "$CUR"
    NOW=$(date +%s%N 2>/dev/null || date +%s)

    # 时间差（秒，含小数；%N 不可用时退化为整数秒）
    DT=$(awk -v a="$PTIME" -v b="$NOW" 'BEGIN{ d=b-a; if (length(a)>10) d/=1e9; if (d<=0) d=1; printf "%.3f", d }')

    # 计算各网卡速率: 输出 "总速率 网卡名 rx速率 tx速率 rx累计 tx累计"
    REPORT=$(awk -v dt="$DT" '
        NR==FNR { prx[$1]=$2; ptx[$1]=$3; next }
        {
            rxr=($2-prx[$1])/dt; txr=($3-ptx[$1])/dt
            if (rxr<0) rxr=0; if (txr<0) txr=0   # 计数器回绕/网卡重启保护
            printf "%.0f %s %.0f %.0f %s %s\n", rxr+txr, $1, rxr, txr, $2, $3
        }' "$PREV" "$CUR")

    # 网卡过滤
    if [ -n "$IFACES" ]; then
        FILTERED=""
        for ifname in $IFACES; do
            LINE=$(printf '%s\n' "$REPORT" | awk -v n="$ifname" '$2==n')
            [ -n "$LINE" ] && FILTERED="$FILTERED$LINE
"
        done
        REPORT=$(printf '%s' "$FILTERED")
    fi

    # 按总速率降序排序
    REPORT=$(printf '%s\n' "$REPORT" | sort -rn -k1,1)

    # 动态列宽: 取最长网卡名的长度（至少留 6，够放表头"网卡"）
    NAMEW=$(printf '%s\n' "$REPORT" | awk '{ l=length($2); if (l>m) m=l } END{ print (m>6 ? m : 6) }')
    SEPW=$((NAMEW + 56))
    SEP=$(printf '%*s' "$SEPW" '' | tr ' ' '-')

    # ---- 绘制界面（原地刷新）----
    # 表头含中文，printf 按字节补齐会对不齐，这里按终端显示宽度手工补齐:
    #   网卡=4列, 接收↓=5列, 发送↑=5列, 累计接收=8列, 累计发送=8列, 合计=4列
    printf '\033[H\033[J'
    printf '\033[1;36mtraffic monitor\033[0m  %s   刷新: %ss   Ctrl+C 退出\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$INTERVAL"
    printf '%s\n' "$SEP"
    printf '\033[1m网卡%*s %9s接收↓ %9s发送↑ %4s累计接收 %4s累计发送\033[0m\n' \
        $((NAMEW - 4)) '' '' '' '' ''
    printf '%s\n' "$SEP"

    TRX=0; TTX=0
    printf '%s\n' "$REPORT" | while read -r _ ifname rxr txr rx_tot tx_tot; do
        [ -z "$ifname" ] && continue
        printf '%-'"$NAMEW"'s %14s %14s %12s %12s\n' \
            "$ifname" "$(human "$rxr")" "$(human "$txr")" \
            "$(humanB "$rx_tot")" "$(humanB "$tx_tot")"
    done

    # 合计（子 shell 里算不出变量，单独用 awk 汇总）
    TOTALS=$(printf '%s\n' "$REPORT" | awk '{r+=$3; t+=$4} END{printf "%.0f %.0f", r, t}')
    set -- $TOTALS
    printf '%s\n' "$SEP"
    printf '\033[1m合计%*s %14s %14s\033[0m\n' $((NAMEW - 4)) '' "$(human "${1:-0}")" "$(human "${2:-0}")"

    cp "$CUR" "$PREV"
    PTIME=$NOW
done
