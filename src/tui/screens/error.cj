package termhelper.tui.screens

import termhelper.tui.components.*

public func renderError(message: String, retryable: Bool): String {
    var out = screenHeader("出现错误", if (retryable) { "可重试" } else { "" })
    out += wrapLine(message, UI_WIDTH, "") + "\n"
    if (retryable) {
        out += sectionTitle("恢复")
        out += emptyState("按 Enter/R 重试上一次请求。")
    }
    out += keyBar("Esc/Ctrl+C 退出")
    out
}
