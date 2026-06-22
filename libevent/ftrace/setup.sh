#!/bin/bash
set -e

LIBEVENT_VERSION="2.1.12-stable"
LIBEVENT_DIR="libevent-${LIBEVENT_VERSION}"
INSTALL_DIR="$(pwd)/libevent_install"

# 下载源码
if [ ! -d "$LIBEVENT_DIR" ]; then
    echo ">>> Downloading libevent-${LIBEVENT_VERSION}..."
    proxychains wget -q https://github.com/libevent/libevent/releases/download/release-${LIBEVENT_VERSION}/${LIBEVENT_DIR}.tar.gz
    tar xzf ${LIBEVENT_DIR}.tar.gz
fi

cd "$LIBEVENT_DIR"

# 配置：静态编译 + 插桩 + 调试符号 + 关闭优化
# LDFLAGS="-rdynamic" \
echo ">>> Configuring libevent with -finstrument-functions..."
./configure \
    CFLAGS="-finstrument-functions -g -O0" \
    --enable-shared \
    --disable-static \
    --prefix="$(pwd)/../libevent_install" \
    --disable-openssl \
    --disable-mbedtls

# 编译
echo ">>> Building libevent..."
make -j$(nproc)

# 安装到本地目录
echo ">>> Installing to $INSTALL_DIR..."
make install

echo ">>> Libevent built successfully at $INSTALL_DIR"
echo ">>> Libraries: $INSTALL_DIR/lib"
echo ">>> Headers: $INSTALL_DIR/include"
echo ">>> Samples source: $(pwd)/sample"
