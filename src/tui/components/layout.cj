package termhelper.tui.components

public let UI_WIDTH: Int64 = 76

public func screenHeader(title: String, status: String): String {
    var out = title
    if (status.size > 0) {
        out += "  " + status
    }
    out += "\n"
    out
}

public func sectionTitle(title: String): String {
    "\n" + title + "\n"
}

public func keyBar(keys: String): String {
    "\n" + keys + "\n"
}

public func bullet(text: String): String {
    "  * " + wrapLine(text, UI_WIDTH - 4, "    ") + "\n"
}

public func field(label: String, value: String): String {
    "  " + label + "：" + wrapLine(value, UI_WIDTH - label.size - 4, repeatText(" ", label.size + 4)) + "\n"
}

public func codeBlock(text: String): String {
    "  $ " + wrapLine(text, UI_WIDTH - 4, "    ") + "\n"
}

public func emptyState(text: String): String {
    "  " + text + "\n"
}

public func repeatText(text: String, count: Int64): String {
    var out = ""
    var i: Int64 = 0
    while (i < count) {
        out += text
        i += 1
    }
    out
}

public func padRight(text: String, width: Int64): String {
    var out = trimToWidth(text, width)
    while (out.size < width) {
        out += " "
    }
    out
}

public func trimToWidth(text: String, width: Int64): String {
    if (width <= 0) {
        return ""
    }
    if (text.size <= width) {
        return text
    }
    if (width <= 3) {
        return text[0..width]
    }
    text[0..(width - 3)] + "..."
}

public func wrapLine(text: String, width: Int64, indent: String): String {
    if (width <= 0 || text.size <= width) {
        return text
    }
    var out = ""
    var remaining = text
    var first = true
    while (remaining.size > width) {
        let chunk = remaining[0..width]
        if (first) {
            out += chunk
            first = false
        } else {
            out += "\n" + indent + chunk
        }
        remaining = remaining[width..]
    }
    if (remaining.size > 0) {
        if (first) {
            out += remaining
        } else {
            out += "\n" + indent + remaining
        }
    }
    out
}
