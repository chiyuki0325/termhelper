#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

STDX_LIB="/home/chiyuki/Documents/Apps/cangjie/stdx/dynamic/stdx"
RATATUI_LIB="thirdparty/ratatui/cangjie-tui-ffi/target/release"
RATATUI_FALLBACK="references/ratatui/cangjie-tui-ffi/target/release"
BUILD_LIBS="target/release/ratatui"

export LD_LIBRARY_PATH="${STDX_LIB}:${BUILD_LIBS}:${LD_LIBRARY_PATH:-}"
unset NO_COLOR

# 追加 ratatui lib
for dir in "$RATATUI_LIB" "$RATATUI_FALLBACK"; do
    if [ -f "$dir/libcangjie_tui.so" ]; then
        export LD_LIBRARY_PATH="${dir}:${LD_LIBRARY_PATH}"
        exec ./target/release/bin/termhelper "$@"
    fi
done

echo "error: libcangjie_tui.so not found" >&2
echo "run: bash scripts/setup-deps.sh && cargo build --release in cangjie-tui-ffi" >&2
exit 1
