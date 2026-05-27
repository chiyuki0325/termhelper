package termhelper.tui.screens

import termhelper.tui.components.*

public func renderLoading(query: String, tick: Int64, streamedText: String, retryText: String): String {
    var out = "termhelper\n"
    out += "==========\n\n"
    out += "${spinnerFrame(tick)} Generating command for:\n"
    out += "  ${query}\n\n"
    if (retryText.size > 0) {
        out += "Retry\n"
        out += "  ${retryText}\n\n"
    }
    out += "Model output\n"
    if (streamedText.size == 0) {
        out += "  Waiting for provider response...\n"
    } else {
        out += streamedText + "\n"
    }
    out += "\nEsc/Ctrl+C: exit\n"
    out
}
