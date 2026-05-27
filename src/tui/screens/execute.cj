package termhelper.tui.screens

import termhelper.types.*
import termhelper.tui.components.*
import std.collection.*

public func renderExecute(command: String, lines: ArrayList<String>, done: Bool, result: ?CommandResult): String {
    var out = screenHeader("命令执行", if (done) { "已结束" } else { "运行中" })
    out += sectionTitle("命令")
    out += codeBlock(command)
    out += sectionTitle("结果")
    out += field("状态", if (done) { "已结束" } else { "运行中" })
    match (result) {
        case Some(r) =>
            out += field("退出码", "${r.exitCode}")
        case None => ()
    }
    out += sectionTitle("输出")
    let start = if (lines.size > 14) { lines.size - 14 } else { 0 }
    for (i in start..lines.size) {
        out += "  " + wrapLine(lines[i], UI_WIDTH - 2, "  ") + "\n"
    }
    if (lines.size == 0) {
        out += emptyState("还没有输出。")
    }
    out += keyBar("Ctrl+C 中断  Esc 返回")
    out
}
