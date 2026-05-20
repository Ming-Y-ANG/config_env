#!/bin/bash
set -euo pipefail

# ═══════════════════════════════════════════
#  配置区 —— 直接改这里
# ═══════════════════════════════════════════

BROKER="localhost"
PORT=1883
USER=""               # 认证用户名，不需要则留空
PASS=""               # 认证密码
CLIENTID="mqtt-3rd"
TOPIC_PREFIX="v1/$CLIENTID/"
QOS=0
RETAIN=0              # 1=启用 retain，0=不启用
DEBUG=0               # 1=打印 mosquitto_pub 调试输出
KEEPALIVE=60

# TLS 配置（不需要则全部留空）
TLS_CAFILE=""
TLS_CERT=""
TLS_KEY=""
TLS_INSECURE=0        # 1=跳过证书校验（仅测试）

# ═══════════════════════════════════════════
#  工具函数
# ═══════════════════════════════════════════

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERR] ${NC}  $*" >&2; }
cmdlog(){ echo -e "${BLUE}[CMD] ${NC}  $*"; }

# 安全的底层发布函数：用数组传参，不用 eval
mqtt_pub() {
    local topic="$1"
    local msg="$2"
    local qos="${3:-$QOS}"
    local retain="${4:-$RETAIN}"

    local args=()
    args+=(-h "$BROKER" -p "$PORT" -q "$qos" -k "$KEEPALIVE")

    [[ -n "$USER" ]] && args+=(-u "$USER")
    [[ -n "$PASS" ]] && args+=(-P "$PASS")
    [[ "$retain" == "1" ]] && args+=(-r)
    [[ "$DEBUG" == "1" ]] && args+=(-d)

    if [[ -n "$TLS_CAFILE" ]]; then
        args+=(--cafile "$TLS_CAFILE")
        [[ -n "$TLS_CERT" ]] && args+=(--cert "$TLS_CERT")
        [[ -n "$TLS_KEY" ]]  && args+=(--key "$TLS_KEY")
        [[ "$TLS_INSECURE" == "1" ]] && args+=(--insecure)
    fi

    args+=(-t "$topic" -m "$msg")

    cmdlog "mosquitto_pub ${args[*]}"
    mosquitto_pub "${args[@]}" && info "发布成功 → [$topic]"
}

# ═══════════════════════════════════════════
#  业务模块 —— 想用哪个就在 main 里取消注释
# ═══════════════════════════════════════════

# 模块：group/set 配置下发
mod_group_set() {
    info "=== group/set ==="

    local payload
    payload='{"client_token":"123","settings":[{"group_name":"group1","interval":10,"interest":{"sysinfo.language":"","sysinfo.hostname":"hostname","sysinfo.timezone":"","sysinfo.model_name":"","sysinfo.oem_name":"","sysinfo.serial_number":"","sysinfo.firmware_version":"","sysinfo.bootloader_version":"","sysinfo.product_number":"","sysinfo.description":"","sysinfo.lan_mac":"","sysinfo.wlan_mac":"","sysinfo.wlan_5g_mac":""}},{"group_name":"group2","interval":10,"interest":{"modem1.ts":"","modem1.active_sim":"","modem1.imei":"IMEI","modem1.imsi":"IMSI","modem1.iccid":"ICCID","modem1.phone_num":"","modem1.signal_lvl":"","modem1.reg_status":"","modem1.operator":"","modem1.network":"","modem1.lac":"","modem1.cell_id":"","modem1.rssi":"","modem1.rsrp":"","modem1.rsrq":"","modem1.sinr":""}},{"group_name":"group3","interval":10,"interest":{"cellular1.ts":"","cellular1.status":"","cellular1.ip":"","cellular1.netmask":"","cellular1.gateway":"","cellular1.dns1":"dns","cellular1.dns2":"DNS","cellular1.up_at":"","cellular1.down_at":"","cellular1.traffic_ts":"","cellular1.tx_bytes":"","cellular1.rx_bytes":""}}]}'

    mqtt_pub "${TOPIC_PREFIX}group/set" "$payload"
}

# 模块：从文件发送（整文件作为一条消息）
mod_file_publish() {
    info "=== file publish ==="

    local file="/tmp/mqtt_test.json"
    cat > "$file" << 'EOF'
{
    "batch": 1,
    "records": [
        {"id": 101, "val": 23.5},
        {"id": 102, "val": 24.0}
    ]
}
EOF

    # 注意：mqtt_pub 用 -m 传字符串；若要用 -f 传文件，可直接调用 mosquitto_pub
    local args=(-h "$BROKER" -p "$PORT" -t "${TOPIC_PREFIX}file" -f "$file" -q "$QOS")
    [[ -n "$USER" ]] && args+=(-u "$USER" -P "$PASS")
    [[ "$DEBUG" == "1" ]] && args+=(-d)

    cmdlog "mosquitto_pub ${args[*]}"
    mosquitto_pub "${args[@]}" && info "文件发送成功 → [$file]"

    rm -f "$file"
}

# ═══════════════════════════════════════════
#  主入口
# ═══════════════════════════════════════════

main() {
    # 检查依赖
    if ! command -v mosquitto_pub &>/dev/null; then
        err "未找到 mosquitto_pub"
        info "安装: apt install mosquitto-clients / yum install mosquitto / brew install mosquitto"
        exit 1
    fi

    info "Broker: $BROKER:$PORT | Client: mqtt_test_$$"

    mod_group_set
}

main "$@"
