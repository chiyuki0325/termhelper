package termhelper.tui.screens

import termhelper.types.*
import termhelper.tui.components.*
import termhelper.i18n.*
import std.collection.*

public func renderExecute(command: String, lines: ArrayList<String>, done: Bool, result: ?CommandResult): String {
    var out = screenHeader(uiText("execute_title"), if (done) {
        uiText("status_done")
    } else {
        uiText("status_running")
    })
    out += sectionTitle(uiText("section_command"))
    out += codeBlock(command)
    out += sectionTitle(uiText("section_result"))
    out += field(uiText("field_status"), if (done) {
        uiText("status_done")
    } else {
        uiText("status_running")
    })
    match (result) {
        case Some(r) => out += field(uiText("field_exit_code"), "${r.exitCode}")
        case None => ()
    }
    out += sectionTitle(uiText("section_output"))
    let start = if (lines.size > 14) {
        lines.size - 14
    } else {
        0
    }
    for (i in start..lines.size) {
        out += "  " + wrapLine(lines[i], UI_WIDTH - 2, "  ") + "\n"
    }
    if (lines.size == 0) {
        out += emptyState(uiText("no_output"))
    }
    out += if (done) {
        keyBar(uiText("keys_execute_done"))
    } else {
        keyBar(uiText("keys_execute_running"))
    }
    out
}
