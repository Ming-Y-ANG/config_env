#!/bin/bash
# put install_gd32isp.sh -> GD32_ISP_CLI_Linux_V5.1.0.39154/GD32_ISP_CLI/bin/
# Setup script for GD32 ISP Console environment.
# Run as root for system-wide install (/usr/local/bin),
# or as normal user for user install (~/.local/bin).
#
# Usage:
#   ./install_gd32isp.sh [gd_isp_root]
#
# Example:
#   ./install_gd32isp.sh /root/gd_isp

set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# Try to auto-detect the tool root from this script's location.
# If this script is inside GD32_ISP_CLI/bin, the tool root is two levels up.
if find "$SCRIPT_DIR" -maxdepth 2 -type d -name 'GD32_ISP_CLI' 2> /dev/null | grep -q .; then
    DEFAULT_GD_ISP_DIR="$SCRIPT_DIR"
else
    DEFAULT_GD_ISP_DIR=$(cd "$SCRIPT_DIR/../.." && pwd)
fi

GD_ISP_DIR="${1:-$DEFAULT_GD_ISP_DIR}"

if [ ! -d "$GD_ISP_DIR" ]; then
    echo "Error: directory not found: $GD_ISP_DIR"
    echo "Usage: $0 [gd_isp_root]"
    exit 1
fi

# Locate the actual CLI binary under the provided directory.
CLI_BIN=$(find "$GD_ISP_DIR" -type f -name 'GD32_ISP_CLI' | head -n 1)

if [ -z "$CLI_BIN" ]; then
    echo "Error: could not find GD32_ISP_CLI binary under $GD_ISP_DIR"
    exit 1
fi

CLI_ABS=$(realpath "$CLI_BIN")

echo "Found GD32 ISP CLI: $CLI_ABS"

# Decide where to install wrappers.
if [ -w "/usr/local/bin" ]; then
    INSTALL_DIR="/usr/local/bin"
else
    INSTALL_DIR="$HOME/.local/bin"
    mkdir -p "$INSTALL_DIR"
fi

# Make sure the install directory is on PATH.
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
    echo ""
    echo "Warning: $INSTALL_DIR is not on your PATH."
    SHELL_PROFILE=""
    if [ -f "$HOME/.bashrc" ]; then
        SHELL_PROFILE="$HOME/.bashrc"
    elif [ -f "$HOME/.zshrc" ]; then
        SHELL_PROFILE="$HOME/.zshrc"
    fi

    if [ -n "$SHELL_PROFILE" ]; then
        echo "Adding $INSTALL_DIR to PATH in $SHELL_PROFILE ..."
        echo "export PATH=\"$INSTALL_DIR:\$PATH\"" >> "$SHELL_PROFILE"
    else
        echo "Please add the following line to your shell profile manually:"
        echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
    fi
    echo "Run 'source $SHELL_PROFILE' or start a new shell after this script."
    echo ""
fi

# 1. Symlink the official tool as GD32_ISP_Console so west runner can find it.
ln -sf "$CLI_ABS" "$INSTALL_DIR/GD32_ISP_Console"
echo "Created symlink: $INSTALL_DIR/GD32_ISP_Console -> $CLI_ABS"

# 2. Install the simplified flash wrapper.
cat > "$INSTALL_DIR/gd32flash" << 'EOF'
#!/bin/bash
# Simple wrapper for GD32_ISP_Console.
# Usage: gd32flash <interface/port> <firmware.bin> [baud]
# Example: gd32flash /dev/ttyUSB0 build/zephyr/zephyr.bin

set -e

PORT="${1:-}"
BIN="${2:-}"
BAUD="${3:-115200}"

if [ -z "$PORT" ] || [ -z "$BIN" ]; then
    echo "Usage: $(basename "$0") <interface/port> <firmware.bin> [baud]"
    echo "Example: $(basename "$0") /dev/ttyUSB0 build/zephyr/zephyr.bin"
    exit 1
fi

if [ ! -f "$BIN" ]; then
    echo "Error: firmware file not found: $BIN"
    exit 1
fi

# Resolve the firmware path before changing directory.
BIN_ABS=$(realpath "$BIN")

CMD_NAME="GD32_ISP_Console"
CMD_PATH=$(command -v "$CMD_NAME" 2> /dev/null)
if [ -z "$CMD_PATH" ]; then
    echo "Error: $CMD_NAME not found in PATH"
    exit 1
fi

# Resolve symlink to the real binary and switch to its directory.
# GD32_ISP_CLI expects to find OptionBytesXML / GD32MCUFlashXML next to it.
CMD_REAL=$(readlink -f "$CMD_PATH")
CMD_DIR=$(dirname "$CMD_REAL")

set -x
# Run inside a subshell so the cd does not affect the parent shell
# if exec fails for any reason.
(
    cd "$CMD_DIR"
    exec "$CMD_REAL" -c \
        --pn "$PORT" \
        --br "$BAUD" \
        --db 8 \
        --pr EVEN \
        --sb 1 \
        --to 5000 \
        -e \
        -d \
        --a 08000000 \
        --fn "$BIN_ABS" \
        --v
)
EOF

chmod +x "$INSTALL_DIR/gd32flash"
echo "Created wrapper: $INSTALL_DIR/gd32flash"

# Verify.
echo ""
echo "Verifying installation..."
if command -v GD32_ISP_Console > /dev/null 2>&1; then
    echo "OK: GD32_ISP_Console is available"
else
    echo "Warning: GD32_ISP_Console still not on PATH in this shell"
fi

if command -v gd32flash > /dev/null 2>&1; then
    echo "OK: gd32flash is available"
else
    echo "Warning: gd32flash still not on PATH in this shell"
fi

echo ""
echo "Done. You can now run:"
echo "  west flash -r gd32isp --device=GD32F403ZET6"
echo "or"
echo "  gd32flash /dev/ttyUSB0 build/zephyr/zephyr.bin"
