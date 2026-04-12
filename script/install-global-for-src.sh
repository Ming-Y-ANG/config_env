#/bin/bash
#gtags global gtags-cscope
set -euo pipefail

log() { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err() { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; exit 1; }

sudo_wrapper() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

install_global() {
    local VERSION="6.6.14"
    local PREFIX="/usr/local"
    local TMP_DIR

    # 已安装直接返回
    if command -v gtags >/dev/null 2>&1; then
        log "GNU Global already installed: $(gtags --version | head -n1)"
        return
    fi

    TMP_DIR=$(mktemp -d)
    cd "$TMP_DIR"

    local TAR="global-$VERSION.tar.gz"
    local URL="https://ftp.gnu.org/pub/gnu/global/$TAR"

    log "Downloading GNU Global..."

    if ! wget "$URL"; then
        rm -rf "$TMP_DIR"
        err "Download failed"
    fi

    log "Extracting..."
    tar xzf "$TAR"

    cd "global-$VERSION"

    log "Configuring..."
    if ! ./configure --prefix="$PREFIX" --with-universal-ctags; then
        rm -rf "$TMP_DIR"
        err "configure failed"
    fi

    log "Building..."
    if ! make -j$(nproc); then
        rm -rf "$TMP_DIR"
        err "make failed"
    fi

    log "Installing..."
    if ! sudo_wrapper make install; then
        rm -rf "$TMP_DIR"
        err "install failed"
    fi

    rm -rf "$TMP_DIR"

    if ! command -v gtags >/dev/null 2>&1; then
        err "gtags not found after install"
    fi

    log "GNU Global installed: $(gtags --version | head -n1)"
}

install_global
