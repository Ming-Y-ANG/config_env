#!/bin/bash

# ==================== 可配置变量 ====================
PREFIX="/root"        # 输出路径（默认系统目录，可改 /root 等）
SERVER_NAME="server"                # 配置名称，生成 server.conf
EASYRSA_DIR="$HOME/easy-rsa"        # easy-rsa 工作目录
# ==================================================

OUTPUT_DIR="$PREFIX/openvpn-server"
OUTPUT_FILE="$OUTPUT_DIR/${SERVER_NAME}.conf"

# 证书来源路径
CA_FILE="$EASYRSA_DIR/pki/ca.crt"
CERT_FILE="$EASYRSA_DIR/pki/issued/${SERVER_NAME}.crt"
KEY_FILE="$EASYRSA_DIR/pki/private/${SERVER_NAME}.key"
DH_FILE="$EASYRSA_DIR/pki/dh.pem"

# 检查证书文件
for f in "$CA_FILE" "$CERT_FILE" "$KEY_FILE" "$DH_FILE"; do
    if [ ! -f "$f" ]; then
        echo "错误: 找不到文件 $f"
        echo "请确认 easy-rsa 证书已生成，或修改 EASYRSA_DIR 路径"
        exit 1
    fi
done

# 创建输出目录
mkdir -p "$OUTPUT_DIR"

# 提取干净 PEM（避免混入文本描述）
openssl x509 -in "$CERT_FILE" -out /tmp/${SERVER_NAME}-clean.crt 2>/dev/null

# 生成内联服务端配置
{
    echo "port 1194"
    echo "proto udp"
    echo "dev tun"
    echo ""
    echo "# 内联证书块"
    echo "<ca>"
    cat "$CA_FILE"
    echo "</ca>"
    echo ""
    echo "<cert>"
    cat /tmp/${SERVER_NAME}-clean.crt
    echo "</cert>"
    echo ""
    echo "<key>"
    cat "$KEY_FILE"
    echo "</key>"
    echo ""
    echo "<dh>"
    cat "$DH_FILE"
    echo "</dh>"
    echo ""
    echo "server 10.8.0.0 255.255.255.0"
    echo "ifconfig-pool-persist /var/log/openvpn/ipp.txt"
    echo 'push "redirect-gateway def1 bypass-dhcp"'
    echo 'push "dhcp-option DNS 8.8.8.8"'
    echo "keepalive 10 120"
    echo "persist-key"
    echo "persist-tun"
    echo "status /var/log/openvpn/openvpn-status.log"
    echo "verb 3"
    echo "explicit-exit-notify 1"
} > "$OUTPUT_FILE"

# 清理临时文件
rm -f /tmp/${SERVER_NAME}-clean.crt

# 设置严格权限（私钥在内，必须限制读取）
chmod 600 "$OUTPUT_FILE"

echo "服务端配置已生成: $OUTPUT_FILE"
ls -la "$OUTPUT_FILE"
