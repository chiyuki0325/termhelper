package termhelper.tui.screens

import termhelper.types.*
import termhelper.tui.components.*
import std.collection.*

public func renderResult(data: CommandData, selected: Int64): String {
    var out = "termhelper - result\n"
    out += "===================\n\n"
    out += renderCommandDisplay(data)
    out += "\n"
    out += renderExplanation(data)
    out += "\n"
    out += renderSafetyBadge(data.safety)
    out += "\n"
    out += renderOptionMenu(resultMenu(data.interactive), selected)
    out += "\nR/C/M shortcuts are available. Esc exits.\n"
    out
}

public func resultMenu(interactive: Bool): ArrayList<MenuItem> {
    let items = ArrayList<MenuItem>()
    if (interactive) {
        items.add(MenuItem("copy", "Copy command (interactive commands run manually in alpha)"))
        items.add(MenuItem("modify", "Modify"))
        items.add(MenuItem("exit", "Exit"))
    } else {
        items.add(MenuItem("run", "Run"))
        items.add(MenuItem("copy", "Copy"))
        items.add(MenuItem("modify", "Modify"))
    }
    items
}
