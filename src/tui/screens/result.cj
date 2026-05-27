package termhelper.tui.screens

import termhelper.types.*
import termhelper.tui.components.*
import std.collection.*

public func renderResult(data: CommandData, selected: Int64): String {
    let mode = if (data.interactive) { "需要交互" } else { "可运行" }
    var out = screenHeader("已生成命令", mode)
    out += renderCommandDisplay(data)
    out += renderExplanation(data)
    out += renderSafetyBadge(data.safety)
    out += renderOptionMenu(resultMenu(data.interactive), selected)
    out += keyBar("上/下 选择  Enter 确认  R 运行  C 复制  M 修改  Esc 退出")
    out
}

public func resultMenu(interactive: Bool): ArrayList<MenuItem> {
    let items = ArrayList<MenuItem>()
    if (interactive) {
        items.add(MenuItem("copy", "复制命令"))
        items.add(MenuItem("modify", "修改"))
        items.add(MenuItem("exit", "退出"))
    } else {
        items.add(MenuItem("run", "运行"))
        items.add(MenuItem("copy", "复制"))
        items.add(MenuItem("modify", "修改"))
    }
    items
}
