package termhelper.tui.screens

import termhelper.types.*
import termhelper.tui.components.*
import std.collection.*

public func renderInvestigate(data: InvestigateData, selected: Int64): String {
    var out = screenHeader("需要环境调查", "${data.commands.size} 项检查")
    out += sectionTitle("原因")
    out += "  " + wrapLine(data.reason, UI_WIDTH - 2, "  ") + "\n"
    out += sectionTitle("诊断命令")
    for (i in 0..data.commands.size) {
        let cmd = data.commands[i]
        let cursor = if (i == selected) { "  > " } else { "    " }
        let mark = if (cmd.authorized) { "[x] " } else { "[ ] " }
        out += cursor + mark + cmd.command + "\n"
        out += "      " + wrapLine(cmd.rationale, UI_WIDTH - 6, "      ") + "\n"
    }
    out += keyBar("Space 切换授权  Enter 运行已授权命令  R 全部授权  Esc 退出")
    out
}

public func renderTextPrompt(title: String, question: String, current: String, sensitive: Bool): String {
    var out = screenHeader(title, "等待输入")
    if (question.size > 0) {
        out += sectionTitle("提示")
        out += wrapLine(question, UI_WIDTH, "") + "\n"
    }
    out += sectionTitle("输入")
    out += "  > "
    if (sensitive) {
        for (_ in 0..current.size) { out += "*" }
    } else {
        out += current
    }
    out += "\n"
    out += keyBar("Enter 提交  Esc 取消")
    out
}

public func investigationSummary(data: InvestigateData, outputs: ArrayList<String>): String {
    var out = "环境调查结果:\n"
    if (data.reason.size > 0) {
        out += "调查原因: ${data.reason}\n"
    }
    for (i in 0..outputs.size) {
        out += outputs[i] + "\n"
    }
    if (outputs.size == 0) {
        out += "用户未授权任何诊断命令。\n"
    }
    out
}
