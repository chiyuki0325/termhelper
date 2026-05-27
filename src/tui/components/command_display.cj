package termhelper.tui.components

import termhelper.types.*

public func renderCommandDisplay(data: CommandData): String {
    var out = "Command\n"
    out += "  ${data.command}\n"
    if (data.explanation.summary.size > 0) {
        out += "\nSummary\n"
        out += "  ${data.explanation.summary}\n"
    }
    out
}
