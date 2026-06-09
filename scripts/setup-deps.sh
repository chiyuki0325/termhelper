#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

NAIVEJSON_URL="https://gitcode.com/zhangyin_gitcode/naivejson_wp.git"
RATATUI_URL="https://gitcode.com/chiyuki0325/ratatui"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}==>${NC} $*"; }
log_warn()  { echo -e "${YELLOW}    warning:${NC} $*"; }
log_error() { echo -e "${RED}    error:${NC} $*"; }

clone_dependency() {
    local name="$1"
    local url="$2"
    local dir="$3"

    if [ ! -d "$dir" ]; then
        log_info "Cloning ${name} from ${url}..."
        git clone --depth 1 "$url" "$dir"
        log_info "${name}: cloned (rev $(git -C "$dir" rev-parse --short HEAD))"
    else
        log_info "${name}: already exists, skipping"
    fi
}

echo "==> Setting up thirdparty dependencies..."

# ── naivejson ──
NAIVEJSON_DIR="thirdparty/naivejson"
clone_dependency "naivejson" "$NAIVEJSON_URL" "$NAIVEJSON_DIR"

# ── ratatui ──
RATATUI_DIR="thirdparty/ratatui"
RATATUI_FFI_DIR="$RATATUI_DIR/cangjie-tui-ffi"

clean_stale_ratatui_dynamic_artifacts() {
    # Avoid stale dynamic SDK artifacts winning over freshly built .a files.
    if [ -d "target/release/ratatui" ]; then
        find "target/release/ratatui" -maxdepth 1 -type f -name '*.so' -delete
    fi
}

patch_ratatui_sdk_link_path() {
    local sdk_toml="$RATATUI_DIR/cangjie-ratatui-sdk/cjpm.toml"
    local ffi_abs_path
    ffi_abs_path="$(pwd)/$RATATUI_FFI_DIR/target/release"

    if [ -f "$sdk_toml" ]; then
        sed -i "s|-L[^ ]*cangjie-tui-ffi/target/release|-L${ffi_abs_path}|g" "$sdk_toml"
        log_info "ratatui SDK: patched FFI link path to ${ffi_abs_path}"
    fi
}

clone_dependency "ratatui" "$RATATUI_URL" "$RATATUI_DIR"

patch_ratatui_sdk_link_path
clean_stale_ratatui_dynamic_artifacts

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
