#!/bin/bash

# ==================== 可配置变量 ====================
SERVER_IP="10.5.29.136"          # 服务器公网 IP 或域名
PREFIX="/root"                      # 输出路径前缀（可改为 /home/xxx 等）
CLIENT_NAME="client1"               # 客户端名称
EASYRSA_DIR="$HOME/easy-rsa"        # easy-rsa 工作目录
# ==================================================

# 自动拼接完整输出路径
OUTPUT_DIR="$PREFIX/openvpn-client"
OUTPUT_FILE="$OUTPUT_DIR/${CLIENT_NAME}.ovpn"

# 证书来源路径
CA_FILE="$EASYRSA_DIR/pki/ca.crt"
CERT_FILE="$EASYRSA_DIR/pki/issued/${CLIENT_NAME}.crt"
KEY_FILE="$EASYRSA_DIR/pki/private/${CLIENT_NAME}.key"

# 检查证书文件是否存在
for f in "$CA_FILE" "$CERT_FILE" "$KEY_FILE"; do
    if [ ! -f "$f" ]; then
        echo "错误: 找不到文件 $f"
        echo "请确认 easy-rsa 证书已生成，或修改 EASYRSA_DIR 路径"
        exit 1
    fi
done

# 创建输出目录
mkdir -p "$OUTPUT_DIR"

# 生成内联证书配置文件
{
    echo "client"
    echo "dev tun"
    echo "proto udp"
    echo "remote $SERVER_IP 1194"
    echo "resolv-retry infinite"
    echo "nobind"
    echo "persist-key"
    echo "persist-tun"
    echo "remote-cert-tls server"
    echo "verb 3"
    echo ""
    echo "<ca>"
    cat "$CA_FILE"
    echo "</ca>"
    echo ""
    echo "<cert>"
    cat "$CERT_FILE"
    echo "</cert>"
    echo ""
    echo "<key>"
    cat "$KEY_FILE"
    echo "</key>"
} > "$OUTPUT_FILE"

chmod 600 "$OUTPUT_FILE"

echo "客户端配置已生成: $OUTPUT_FILE"
ls -la "$OUTPUT_FILE"
