#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

NAIVEJSON_URL="https://gitcode.com/zhangyin_gitcode/naivejson_wp.git"
RATATUI_URL="https://gitcode.com/chiyuki0325/ratatui"
STDX_VERSION="1.1.3.1"
STDX_BASE_URL="https://gitcode.com/Cangjie/cangjie_stdx/releases/download/v${STDX_VERSION}"

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

detect_std_arch() {
    case "$(uname -m)" in
        x86_64|amd64)
            STDX_ARCH="x64"
            STDX_DIR_NAME="linux_x86_64_cjnative"
            STDX_TARGET_TRIPLE="x86_64-unknown-linux-gnu"
            ;;
        aarch64|arm64)
            STDX_ARCH="aarch64"
            STDX_DIR_NAME="linux_aarch64_cjnative"
            STDX_TARGET_TRIPLE="aarch64-unknown-linux-gnu"
            ;;
        *)
            log_error "unsupported architecture for bundled stdx: $(uname -m)"
            exit 1
            ;;
    esac
}

download_file() {
    local url="$1"
    local output="$2"

    if command -v curl &>/dev/null; then
        curl -L --fail -o "$output" "$url"
    elif command -v wget &>/dev/null; then
        wget -O "$output" "$url"
    else
        log_error "curl or wget is required to download stdx"
        exit 1
    fi
}

setup_stdlib_extension() {
    detect_std_arch

    local stdx_root="thirdparty/stdx"
    local stdx_dir="$stdx_root/$STDX_DIR_NAME"
    local static_stdx_dir="$stdx_dir/static/stdx"
    local zip_name="cangjie-stdx-linux-${STDX_ARCH}-${STDX_VERSION}.zip"
    local zip_url="${STDX_BASE_URL}/${zip_name}"
    local tmp_zip

    if [ -d "$static_stdx_dir" ]; then
        log_info "stdx: already exists ($static_stdx_dir), skipping download"
    else
        log_info "Downloading stdx ${STDX_VERSION} for ${STDX_TARGET_TRIPLE}..."
        mkdir -p "$stdx_root"
        tmp_zip="$(mktemp)"
        download_file "$zip_url" "$tmp_zip"
        unzip -q "$tmp_zip" -d "$stdx_root"
        rm -f "$tmp_zip"

        if [ ! -d "$static_stdx_dir" ]; then
            log_error "stdx archive did not contain expected directory: $static_stdx_dir"
            exit 1
        fi
        log_info "stdx: installed to $stdx_dir"
    fi
}

patch_naivejson_stdx_path() {
    local naivejson_toml="$NAIVEJSON_DIR/naivejson/cjpm.toml"
    local stdx_static_abs

    stdx_static_abs="$(pwd)/thirdparty/stdx/${STDX_DIR_NAME}/static/stdx"
    if [ ! -d "$stdx_static_abs" ]; then
        log_error "stdx static directory missing: $stdx_static_abs"
        exit 1
    fi

    if [ -f "$naivejson_toml" ]; then
        case "$STDX_TARGET_TRIPLE" in
            x86_64-unknown-linux-gnu)
                sed -i "s|\${CANGJIE_STDX_PATH}/linux_x86_64_llvm/static/stdx|${stdx_static_abs}|g" "$naivejson_toml"
                ;;
            aarch64-unknown-linux-gnu)
                sed -i "s|\${CANGJIE_STDX_PATH}/linux_aarch64_llvm/static/stdx|${stdx_static_abs}|g" "$naivejson_toml"
                ;;
        esac
        log_info "naivejson: patched stdx path to ${stdx_static_abs}"
    fi
}

echo "==> Setting up thirdparty dependencies..."

# ── stdx ──
setup_stdlib_extension

# ── naivejson ──
NAIVEJSON_DIR="thirdparty/naivejson"
clone_dependency "naivejson" "$NAIVEJSON_URL" "$NAIVEJSON_DIR"
patch_naivejson_stdx_path

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

patch_project_ratatui_link_path() {
    local project_toml="cjpm.toml"
    local ffi_abs_path
    ffi_abs_path="$(pwd)/$RATATUI_FFI_DIR/target/release"

    sed -i "s|-L[^ ]*cangjie-tui-ffi/target/release|-L${ffi_abs_path}|g" "$project_toml"
    log_info "project: patched ratatui FFI link path to ${ffi_abs_path}"
}

clone_dependency "ratatui" "$RATATUI_URL" "$RATATUI_DIR"

patch_ratatui_sdk_link_path
patch_project_ratatui_link_path
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
echo "    stdx:      thirdparty/stdx/$STDX_DIR_NAME/"
echo ""
echo "Run: cjpm build"
