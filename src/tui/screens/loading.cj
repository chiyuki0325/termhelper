package termhelper.tui.screens

import termhelper.tui.components.*

public func renderLoading(query: String, tick: Int64, streamedText: String, retryText: String): String {
    var out = screenHeader("正在生成命令", spinnerFrame(tick))
    out += sectionTitle("查询")
    out += "  " + wrapLine(query, UI_WIDTH - 2, "  ") + "\n"
    if (retryText.size > 0) {
        out += sectionTitle("重试")
        out += "  " + wrapLine(retryText, UI_WIDTH - 2, "  ") + "\n"
    }
    out += sectionTitle("模型响应")
    if (streamedText.size == 0) {
        out += emptyState("正在等待模型响应...")
    } else {
        out += wrapLine(streamedText, UI_WIDTH, "") + "\n"
    }
    out += keyBar("Esc/Ctrl+C 退出")
    out
}
