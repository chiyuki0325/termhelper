package termhelper.tui.screens

import termhelper.tui.components.*
import termhelper.i18n.*

public func renderError(message: String, retryable: Bool): String {
    var out = screenHeader(uiText("error_title"), if (retryable) {
        uiText("retryable")
    } else {
        ""
    })
    out += wrapLine(message, UI_WIDTH, "") + "\n"
    if (retryable) {
        out += sectionTitle(uiText("section_recovery"))
        out += emptyState(uiText("retry_hint"))
    }
    out += keyBar(uiText("keys_exit"))
    out
}
