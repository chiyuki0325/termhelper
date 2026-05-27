package termhelper.tui.components

import termhelper.types.*

public func renderExplanation(data: CommandData): String {
    var out = "Breakdown\n"
    if (data.explanation.breakdown.size == 0) {
        return out + "  No breakdown provided.\n"
    }
    for (item in data.explanation.breakdown) {
        out += "  " + padRight(item.component, 18) + " " + item.explanation + "\n"
    }
    out
}

func padRight(text: String, width: Int64): String {
    var out = text
    while (out.size < width) {
        out += " "
    }
    out
}
