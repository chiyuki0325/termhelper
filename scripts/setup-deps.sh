#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

NAIVEJSON_URL="https://gitcode.com/zhangyin_gitcode/naivejson_wp.git"
RATATUI_URL="https://gitcode.com/Cangjie-SIG/ratatui/"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}==>${NC} $*"; }
log_warn()  { echo -e "${YELLOW}    warning:${NC} $*"; }
log_error() { echo -e "${RED}    error:${NC} $*"; }

echo "==> Setting up thirdparty dependencies..."

# ── naivejson ──
NAIVEJSON_DIR="thirdparty/naivejson"
if [ ! -d "$NAIVEJSON_DIR" ]; then
    log_info "Cloning naivejson from ${NAIVEJSON_URL}..."
    if git clone --depth 1 "$NAIVEJSON_URL" "$NAIVEJSON_DIR" 2>/dev/null; then
        log_info "naivejson: cloned (rev $(git -C "$NAIVEJSON_DIR" rev-parse --short HEAD))"
    else
        log_warn "git clone failed, falling back to local reference"
        cp -a references/naivejson_wp "$NAIVEJSON_DIR"
        log_info "naivejson: copied from references/"
    fi
else
    log_info "naivejson: already exists, skipping"
fi

# ── ratatui ──
RATATUI_DIR="thirdparty/ratatui"
RATATUI_FFI_DIR="$RATATUI_DIR/cangjie-tui-ffi"
PATCHES_DIR="patches"

if [ ! -d "$RATATUI_DIR" ]; then
    log_info "Cloning ratatui from ${RATATUI_URL}..."
    if git clone --depth 1 "$RATATUI_URL" "$RATATUI_DIR" 2>/dev/null; then
        log_info "ratatui: cloned (rev $(git -C "$RATATUI_DIR" rev-parse --short HEAD))"

        # Apply patches
        if [ -d "$PATCHES_DIR" ]; then
            shopt -s nullglob
            for patch in "$PATCHES_DIR"/*.patch; do
                log_info "Applying $(basename "$patch")..."
                if ! (cd "$RATATUI_DIR" && patch -p1 < "../..//$patch"); then
                    log_warn "$(basename "$patch") may already be applied"
                fi
            done
            shopt -u nullglob
        fi

        # Ensure cjpm.toml link-option uses relative path (patch sets absolute)
        SDK_TOML="$RATATUI_DIR/cangjie-ratatui-sdk/cjpm.toml"
        if [ -f "$SDK_TOML" ]; then
            # Replace any absolute -L path pointing to cangjie-tui-ffi with a relative one
            sed -i 's|-L[^ ]*cangjie-tui-ffi/target/release|-L../../thirdparty/ratatui/cangjie-tui-ffi/target/release|g' "$SDK_TOML"
        fi
    else
        log_warn "git clone failed, falling back to local reference"
        cp -a references/ratatui "$RATATUI_DIR"

        # Apply patches for local copy too
        if [ -d "$PATCHES_DIR" ]; then
            shopt -s nullglob
            for patch in "$PATCHES_DIR"/*.patch; do
                log_info "Applying $(basename "$patch")..."
                (cd "$RATATUI_DIR" && patch -p1 < "../..//$patch") 2>/dev/null || \
                    log_warn "$(basename "$patch") may already be applied"
            done
            shopt -u nullglob
        fi
    fi
else
    log_info "ratatui: already exists, skipping"
fi

# ── Build Rust FFI ──
log_info "Building ratatui Rust FFI..."
if command -v cargo &>/dev/null; then
    if (cd "$RATATUI_FFI_DIR" && cargo build --release 2>&1); then
        log_info "rust FFI: done ($RATATUI_FFI_DIR/target/release/)"
    else
        log_warn "cargo build failed, check Rust toolchain"
    fi
else
    log_warn "cargo not found, skipping Rust FFI build"
    log_warn "install Rust: https://rustup.rs"
fi

echo ""
echo "==> Setup complete!"
echo "    naivejson: $NAIVEJSON_DIR/"
echo "    ratatui:   $RATATUI_DIR/"
echo ""
echo "Run: cjpm build"
