#!/usr/bin/env bash
set -euo pipefail

log() { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err() { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; exit 1; }

program_exists() {
    command -v "$1" >/dev/null 2>&1
}

sudo_wrapper() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

normalize_ver() {
    echo "$1" | sed 's/^v//'
}

version_lt() {
    [ "$(printf '%s\n' "$(normalize_ver "$1")" "$(normalize_ver "$2")" | sort -V | head -n1)" != "$(normalize_ver "$2")" ]
}

install_nodejs() {
    local VERSION="v20.9.0"
    local PREFIX="/usr/local"
    local FORCE_INSTALL="${FORCE_NODE:-0}"

    local TMP_DIR
    TMP_DIR=$(mktemp -d)

    local NEED_INSTALL=0

    if ! program_exists node; then
        NEED_INSTALL=1
    else
        local CUR_VER
        CUR_VER=$(node -v)

        if version_lt "$CUR_VER" "$VERSION" || [ "$FORCE_INSTALL" -eq 1 ]; then
            NEED_INSTALL=1
        fi
    fi

    if [ "$NEED_INSTALL" -eq 0 ]; then
        log "Node OK: $(node -v)"
        rm -rf "$TMP_DIR"
        return
    fi

    local PACK="node-$VERSION-linux-x64.tar.gz"
    local URL="https://nodejs.org/dist/$VERSION/$PACK"

    log "Downloading Node: $URL"

    if ! wget -q --show-progress "$URL" -O "$TMP_DIR/$PACK"; then
        rm -rf "$TMP_DIR"
        err "Download failed"
    fi

    if [ ! -s "$TMP_DIR/$PACK" ]; then
        rm -rf "$TMP_DIR"
        err "Downloaded file is empty"
    fi

    log "Extracting..."

    if ! tar xzf "$TMP_DIR/$PACK" -C "$TMP_DIR"; then
        rm -rf "$TMP_DIR"
        err "Extract failed"
    fi

    local SRC="$TMP_DIR/node-$VERSION-linux-x64"

    if [ ! -d "$SRC" ]; then
        rm -rf "$TMP_DIR"
        err "Extracted directory not found"
    fi

    log "Installing Node atomically..."

    local STAGE_DIR
    STAGE_DIR=$(mktemp -d /tmp/node-stage-XXXX)

    sudo_wrapper rm -rf "$STAGE_DIR"
    sudo_wrapper mkdir -p "$STAGE_DIR"

    if ! sudo_wrapper cp -r "$SRC"/* "$STAGE_DIR"; then
        rm -rf "$TMP_DIR"
        err "Copy to stage dir failed"
    fi

    if [ -d "$PREFIX" ]; then
        sudo_wrapper mv "$PREFIX" "${PREFIX}.bak.$(date +%s)" || true
    fi

    if ! sudo_wrapper mv "$STAGE_DIR" "$PREFIX"; then
        rm -rf "$TMP_DIR"
        err "Install failed (mv)"
    fi

    rm -rf "$TMP_DIR"

    if ! command -v node >/dev/null 2>&1; then
        err "node not found after install"
    fi

    if ! npm -v >/dev/null 2>&1; then
        err "npm not working after install"
    fi

    log "Node installed: $(node -v)"
    log "npm  version : $(npm -v)"
}


npm_update() {
    local REQ_VER="9.5.1"

    if ! program_exists npm; then
        err "npm not found, please check node install..."
        exit
    fi

    local CUR_VER
    CUR_VER=$(npm -v)

    if version_lt "$CUR_VER" "$REQ_VER"; then
        log "npm upgrade: $CUR_VER -> $REQ_VER"
        sudo_wrapper npm install -g "npm@$REQ_VER"
    else
        log "npm OK: $CUR_VER"
    fi
    #bash lsp
    #sudo_wrapper npm i -g bash-language-server
}

install_utilities() {
    log "Installing utilities..."
    sudo_wrapper apt update
    local PKGS=(
        build-essential
        unzip wget curl git tig expect
        bear autoconf proxychains
        universal-ctags
        tmux vim libncurses5-dev libncursesw5-dev pkg-config
        libtool gettext
    )
    if [ "$ID" = "ubuntu" ]; then
        PKGS+=(software-properties-common)
    fi

    sudo_wrapper apt install -y "${PKGS[@]}"
    cp tmux.conf ${HOME}/.tmux.conf
}

install_tools() {
    log "Installing tools..."

    if [ ! -d tools ]; then
        warn "tools dir not found, skip"
        return
    fi

    cp -r tools "$HOME/tools"
}

configure_bashrc() {
    log "Configuring .bashrc..."
    #check if it is configured
    [ -z "$(grep 'begin:user custom definition' ~/.bashrc)" ] || {
        log "bashrc is configured, skip"
        return
    }

    if grep -q "begin:user custom definition" ~/.bashrc; then
        log ".bashrc already configured"
        return
    fi

    local TMP_FILE
    TMP_FILE=$(mktemp)

    cp ~/.bashrc "$TMP_FILE"

    cat >> "$TMP_FILE" <<'EOF'

#===========begin:user custom definition=========
alias g='grep -nr --color=auto'
alias ls='ls --color'
alias rm='rm -i'

alias man="LESS_TERMCAP_mb=$'\e[01;31m' \
LESS_TERMCAP_md=$'\e[01;38;5;170m' \
LESS_TERMCAP_me=$'\e[0m' \
LESS_TERMCAP_se=$'\e[0m' \
LESS_TERMCAP_so=$'\e[38;5;246m' \
LESS_TERMCAP_ue=$'\e[0m' \
LESS_TERMCAP_us=$'\e[04;38;5;74m' man"

export PATH=$HOME/tools:$PATH
export EDITOR=vim
#===========end:user custom definition=========

EOF

    mv "$TMP_FILE" ~/.bashrc
    source ~/.bashrc
}

configure_gitconfig() {
    log "Configuring git..."

    git config --global user.name "${GIT_USERNAME:-yangming}"
    git config --global user.email "${GIT_EMAIL:-yangming@inhand.com.cn}"

    git config --global core.editor vim
    git config --global merge.tool vimdiff

    git config --global alias.co checkout
    git config --global alias.br branch
    git config --global alias.ci commit
    git config --global alias.st status
    git config --global alias.rb rebase
    git config --global alias.cp cherry-pick
    git config --global push.default simple
    git config --global credential.helper store
    #HTTP2 may cause 'clone succeeded, but checkout failed', set as bellow solve it
    #git config --global http.version HTTP/1.1
}

configure_vim() {
    log "Configuring vim..."

    if [ ! -d vim ]; then
        warn "vim config not found"
        return
    fi
    if [ ! -d $HOME/.vim ]; then
		mkdir -p $HOME/.vim
    fi

    cp -r vim/* "$HOME/.vim/"
    ln -sf "$HOME/.vim/init.vim" "$HOME/.vimrc"
}

detect_os() {
    [ -f /etc/os-release ] || err "Unsupported OS"

    source /etc/os-release

    if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
        err "Only support Ubuntu/Debian"
	exit 
    fi

    log "Detected OS: $ID $VERSION_ID"
}

main() {
    log "Config start... "
    detect_os
    install_utilities
    install_nodejs
    npm_update
    install_tools
    configure_bashrc
    configure_gitconfig
    configure_vim

    log "All done... "
}

main "$@"
