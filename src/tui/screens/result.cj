package termhelper.tui.screens

import termhelper.types.*
import termhelper.tui.components.*
import termhelper.i18n.*
import std.collection.*

public func renderResult(data: CommandData, selected: Int64): String {
    let mode = if (data.interactive) {
        uiText("mode_interactive")
    } else {
        uiText("mode_runnable")
    }
    var out = screenHeader(uiText("result_title"), mode)
    out += renderCommandDisplay(data)
    out += renderExplanation(data)
    out += renderSafetyBadge(data.safety)
    out += renderOptionMenu(resultMenu(data.interactive), selected)
    out += keyBar(uiText("keys_result"))
    out
}

public func resultMenu(interactive: Bool): ArrayList<MenuItem> {
    let items = ArrayList<MenuItem>()
    if (interactive) {
        items.add(MenuItem("copy", uiText("menu_copy_command")))
        items.add(MenuItem("modify", uiText("menu_modify")))
        items.add(MenuItem("exit", uiText("menu_exit")))
    } else {
        items.add(MenuItem("run", uiText("menu_run")))
        items.add(MenuItem("copy", uiText("menu_copy")))
        items.add(MenuItem("modify", uiText("menu_modify")))
    }
    items
}
