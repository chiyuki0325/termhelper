export CANGJIE_STDX_PATH="${CANGJIE_STDX_PATH:-/home/chiyuki/Documents/Apps/cangjie/stdx}"
export CANGJIE_HOME="${CANGJIE_HOME:-/home/chiyuki/Documents/Apps/cangjie}"

LD_LIBRARY_PATH=target/release/ratatui:$CANGJIE_STDX_PATH/dynamic/stdx:$PWD/references/ratatui/cangjie-tui-ffi/target/release:$CANGJIE_HOME/runtime/lib/linux_$(uname -m)_cjnative target/release/bin/termhelper $@
