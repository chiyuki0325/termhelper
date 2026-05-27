package termhelper.tui.screens

import termhelper.types.*
import std.collection.*

public func renderExecute(command: String, lines: ArrayList<String>, done: Bool, result: ?CommandResult): String {
    var out = "termhelper - execute\n"
    out += "====================\n\n"
    out += "Command\n"
    out += "  ${command}\n\n"
    out += if (done) { "Status: finished\n" } else { "Status: running\n" }
    match (result) {
        case Some(r) =>
            out += "Exit code: ${r.exitCode}\n"
        case None => ()
    }
    out += "\nOutput\n"
    let start = if (lines.size > 18) { lines.size - 18 } else { 0 }
    for (i in start..lines.size) {
        out += lines[i] + "\n"
    }
    out += "\nCtrl+C: interrupt  Esc: back to result/exit\n"
    out
}
