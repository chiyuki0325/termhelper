package termhelper.tui.components

import termhelper.i18n.*

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
    let sep = if (isChinese()) {
        "："
    } else {
        ": "
    }
    "  " + label + sep + wrapLine(value, UI_WIDTH - label.size - 4, repeatText(" ", label.size + 4)) + "\n"
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
    while (displayWidth(out) < width) {
        out += " "
    }
    out
}

public func trimToWidth(text: String, width: Int64): String {
    if (width <= 0) {
        return ""
    }
    if (displayWidth(text) <= width) {
        return text
    }
    if (width <= 3) {
        return fitToWidth(text, width)
    }
    fitToWidth(text, width - 3) + "..."
}

/// Flatten untrusted overlay text into a bounded single line before it crosses
/// the ratatui FFI boundary. Very long one-line spans can trigger coordinate
/// overflow inside the renderer.
public func compactOverlayText(text: String, maxRunes: Int64): String {
    if (maxRunes <= 0) {
        return ""
    }
    var count: Int64 = 0
    let result = StringBuilder()
    for (r in text.runes()) {
        if (count >= maxRunes) {
            result.append("...")
            return result.toString()
        }
        if (r == r'\n' || r == r'\r' || r == r'\t') {
            result.append(" ")
        } else {
            result.append(String(r))
        }
        count += 1
    }
    result.toString()
}

public func overlayValueLimit(width: Int64): Int64 {
    let usable = if (width > 16) { width - 16 } else { 40 }
    if (usable < 40) {
        40
    } else if (usable > 160) {
        160
    } else {
        usable
    }
}

public func wrapLine(text: String, width: Int64, indent: String): String {
    if (width <= 0 || displayWidth(text) <= width) {
        return text
    }
    var out = ""
    var first = true
    var line = ""
    var lineWidth: Int64 = 0

    for (r in text.runes()) {
        let piece = String(r)
        let pieceWidth = runeWidth(piece)
        if (lineWidth > 0 && lineWidth + pieceWidth > width) {
            if (first) {
                out += line
                first = false
            } else {
                out += "\n" + indent + line
            }
            line = piece
            lineWidth = pieceWidth
        } else {
            line += piece
            lineWidth += pieceWidth
        }
    }

    if (line.size > 0) {
        if (first) {
            out += line
        } else {
            out += "\n" + indent + line
        }
    }
    out
}

public func displayWidth(text: String): Int64 {
    var width: Int64 = 0
    for (r in text.runes()) {
        width += runeWidth(String(r))
    }
    width
}

func fitToWidth(text: String, width: Int64): String {
    var out = ""
    var used: Int64 = 0
    for (r in text.runes()) {
        let piece = String(r)
        let pieceWidth = runeWidth(piece)
        if (used + pieceWidth > width) {
            return out
        }
        out += piece
        used += pieceWidth
    }
    out
}

func runeWidth(piece: String): Int64 {
    if (piece.size > 1) {
        2
    } else {
        1
    }
}
