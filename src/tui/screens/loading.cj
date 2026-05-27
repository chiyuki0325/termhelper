package termhelper.tui.screens

import termhelper.tui.components.*
import termhelper.i18n.*

public func renderLoading(query: String, tick: Int64, streamedText: String, retryText: String): String {
    var out = screenHeader(uiText("loading_title"), spinnerFrame(tick))
    out += sectionTitle(uiText("section_query"))
    out += "  " + wrapLine(query, UI_WIDTH - 2, "  ") + "\n"
    if (retryText.size > 0) {
        out += sectionTitle(uiText("section_retry"))
        out += "  " + wrapLine(retryText, UI_WIDTH - 2, "  ") + "\n"
    }
    out += sectionTitle(uiText("section_model_response"))
    if (streamedText.size == 0) {
        out += emptyState(uiText("waiting_model"))
    } else {
        out += wrapLine(streamedText, UI_WIDTH, "") + "\n"
    }
    out += keyBar(uiText("keys_exit"))
    out
}
