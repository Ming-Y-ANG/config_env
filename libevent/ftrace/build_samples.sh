#!/bin/bash
set -e

INSTALL_DIR="$(pwd)/libevent_install"
LIBEVENT_SRC="$(pwd)/libevent-2.1.12-stable"
SAMPLES_DIR="$LIBEVENT_SRC/sample"

if [ ! -d "$SAMPLES_DIR" ]; then
    echo "Error: libevent source not found. Run ./setup.sh first."
    exit 1
fi

# 编译参数
CFLAGS="-finstrument-functions -g -O0 -I$INSTALL_DIR/include -I$LIBEVENT_SRC/include"
LDFLAGS="-L$INSTALL_DIR/lib -levent -Wl,-rpath,$INSTALL_DIR/lib -rdynamic"
HOOKS="$(pwd)/trace_hooks.o"

echo ">>> Building sample demos with instrumentation..."

gcc -g -O0 -fPIC -c -o trace_hooks.o trace_hooks.c

cd "$SAMPLES_DIR"

# 编译 time-test（最简单的定时器示例）
echo "Building time-test..."
gcc $CFLAGS -o time-test-traced time-test.c $HOOKS $LDFLAGS -ldl -lpthread || true

# 编译 event-test（事件测试）
#echo "Building event-test..."
#gcc $CFLAGS -o event-test-traced event-test.c $HOOKS $LDFLAGS -ldl -lpthread || true

# 编译 http-server（HTTP 服务示例）
echo "Building http-server..."
gcc $CFLAGS -o http-server-traced http-server.c $HOOKS $LDFLAGS -ldl -lpthread || true

# 编译 hello-world（最简单的示例）
echo "Building hello-world..."
gcc $CFLAGS -o hello-world-traced hello-world.c $HOOKS $LDFLAGS -ldl -lpthread || true

echo ">>> Built samples:"
ls -la *-traced 2>/dev/null || echo "Some builds may have failed (check dependencies)"

# 复制到项目根目录方便运行
cp *-traced "$OLDPWD/" 2>/dev/null || true
cd "$OLDPWD"
