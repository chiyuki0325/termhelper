package termhelper.tui.screens

import termhelper.types.*
import termhelper.tui.components.*
import termhelper.i18n.*
import std.collection.*

public func renderInvestigate(data: InvestigateData, selected: Int64): String {
    var out = screenHeader(uiText("investigate_title"), uiCountChecks(data.commands.size))
    out += sectionTitle(uiText("section_reason"))
    out += "  " + wrapLine(data.reason, UI_WIDTH - 2, "  ") + "\n"
    out += sectionTitle(uiText("section_diagnostic_commands"))
    for (i in 0..data.commands.size) {
        let cmd = data.commands[i]
        let cursor = if (i == selected) {
            "  > "
        } else {
            "    "
        }
        let mark = if (cmd.authorized) {
            "[x] "
        } else {
            "[ ] "
        }
        out += cursor + mark + cmd.command + "\n"
        out += "      " + wrapLine(cmd.rationale, UI_WIDTH - 6, "      ") + "\n"
    }
    out += keyBar(uiText("keys_investigate"))
    out
}

public func renderTextPrompt(title: String, question: String, current: String, sensitive: Bool): String {
    var out = screenHeader(title, uiText("waiting_input"))
    if (question.size > 0) {
        out += sectionTitle(uiText("section_prompt"))
        out += wrapLine(question, UI_WIDTH, "") + "\n"
    }
    out += sectionTitle(uiText("section_input"))
    out += "  > "
    if (sensitive) {
        for (_ in 0..current.size) {
            out += "*"
        }
    } else {
        out += current
    }
    out += "\n"
    out += keyBar(uiText("keys_submit_cancel"))
    out
}

public func investigationSummary(data: InvestigateData, outputs: ArrayList<String>): String {
    var out = uiText("investigation_results") + "\n"
    if (data.reason.size > 0) {
        out += uiText("investigation_reason") + ": ${data.reason}\n"
    }
    for (i in 0..outputs.size) {
        out += outputs[i] + "\n"
    }
    if (outputs.size == 0) {
        out += uiText("no_authorized_diagnostics") + "\n"
    }
    out
}
