package termhelper.tui.screens

public func renderError(message: String, retryable: Bool): String {
    var out = "termhelper - error\n"
    out += "==================\n\n"
    out += message + "\n\n"
    if (retryable) {
        out += "Enter/R: retry\n"
    }
    out += "Esc/Ctrl+C: exit\n"
    out
}
