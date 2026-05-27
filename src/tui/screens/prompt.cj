package termhelper.tui.screens

import termhelper.types.*
import std.collection.*

public func renderInvestigate(data: InvestigateData, selected: Int64): String {
    var out = "termhelper - investigation\n"
    out += "==========================\n\n"
    out += "Reason\n"
    out += "  ${data.reason}\n\n"
    out += "Diagnostic commands\n"
    for (i in 0..data.commands.size) {
        let cmd = data.commands[i]
        let cursor = if (i == selected) { "> " } else { "  " }
        let mark = if (cmd.authorized) { "[x] " } else { "[ ] " }
        out += cursor + mark + cmd.command + "\n"
        out += "      " + cmd.rationale + "\n"
    }
    out += "\nSpace: toggle  Enter: run authorized  R: authorize all  Esc: exit\n"
    out
}

public func renderTextPrompt(title: String, question: String, current: String, sensitive: Bool): String {
    var out = "termhelper - ${title}\n"
    out += "====================\n\n"
    out += question + "\n\n"
    out += "> "
    if (sensitive) {
        for (_ in 0..current.size) { out += "*" }
    } else {
        out += current
    }
    out += "\n\nEnter: submit  Esc: cancel\n"
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
