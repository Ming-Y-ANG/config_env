#!/usr/bin/env bash
# When OpenSSL prompts you for the Common Name(CN = your.domain.com or IP) for each certificate, MUST use different names.

#server IP
server_cn='10.5.29.137'

if [ ! -e certs ]; then
	mkdir certs
fi

cd certs

# CA key
openssl genrsa -out ca.key 2048
# CA csr
openssl req -new -subj "/CN=ca" -key ca.key -out ca.csr
# CA crt
openssl x509 -req -in ca.csr -out ca.crt -signkey ca.key -days 3650

# server key
openssl genrsa -out server.key 2048
# server.csr
openssl req -new -subj "/CN=$server_cn" -key server.key -out server.csr
# server.crt
openssl x509 -req -in server.csr -out server.crt -CA ca.crt -CAkey ca.key \
-CAcreateserial -days 3650
# server.crt verify
openssl verify -CAfile ca.crt  server.crt

# client key
openssl genrsa -out client.key 2048
# client.csr
openssl req -new -subj "/CN=client" -key client.key -out client.csr
# client.crt
openssl x509 -req -in client.csr -out client.crt -CA ca.crt -CAkey ca.key \
-CAcreateserial -days 3650
# client.crt verify
openssl verify -CAfile ca.crt  client.crt

cd ..

#使用自签名证书时，CA证书 和 server证书 的 Comon Name 使用了相同的内容；这样会导致 OpenSSL 校验证书时失败，将 CA证书 和 server证书的 Comon Name 改成不同的内容即可；
#使用自签名证书时，server证书 的 Comon Name 与域名不相符，默认情况下客户端会连接错误，这时在连接时加入 --insecure 参数即可；
#使用自签名证书时，如果CA是单个文件，将 --cafile 参数错写成 --capath；
#服务端开启双向认证 require_certificate true , 连接时没有传入客户端的证书和密钥；
#服务端与客户端的 TLS 版本不一致，服务端配置参数为 tls_version ，客户端配置参数为 --tls-version；
