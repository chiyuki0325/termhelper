package termhelper.tui.components

import ratatui.core.*

public class RichStyle {
    public let fg: Int32
    public let bg: Int32
    public let modifiers: Int32

    public init(fg: Int32, bg: Int32, modifiers: Int32) {
        this.fg = fg
        this.bg = bg
        this.modifiers = modifiers
    }
}

let COLOR_DEFAULT: Int32 = 0
let COLOR_RED: Int32 = 2
let COLOR_YELLOW: Int32 = 4
let COLOR_CYAN: Int32 = 7
let COLOR_DARK_GRAY: Int32 = 9
let COLOR_LIGHT_RED: Int32 = 10
let COLOR_LIGHT_GREEN: Int32 = 11
let COLOR_LIGHT_YELLOW: Int32 = 12
let COLOR_LIGHT_BLUE: Int32 = 13
let COLOR_LIGHT_CYAN: Int32 = 15
let COLOR_WHITE: Int32 = 16
let MOD_BOLD: Int32 = 1
let MOD_UNDERLINED: Int32 = 8

public func createRichTextWidget(): Result<Int64, RatatuiException> {
    createStyledTextWidget()
}

public func richTextSpan(handle: Int64, text: String, style: RichStyle): Unit {
    let _ = addStyledTextSpan(handle, text, style.fg, style.bg, style.modifiers)
}

public func richTextLine(handle: Int64): Unit {
    let _ = addStyledTextLineBreak(handle)
}

public func richTextLine(handle: Int64, text: String, style: RichStyle): Unit {
    richTextSpan(handle, text, style)
    richTextLine(handle)
}

public func styleDefault(): RichStyle {
    RichStyle(COLOR_DEFAULT, COLOR_DEFAULT, 0)
}

public func styleTitle(): RichStyle {
    RichStyle(COLOR_LIGHT_CYAN, COLOR_DEFAULT, MOD_BOLD)
}

public func styleSection(): RichStyle {
    RichStyle(COLOR_CYAN, COLOR_DEFAULT, MOD_BOLD)
}

public func styleCommand(): RichStyle {
    RichStyle(COLOR_LIGHT_YELLOW, COLOR_DEFAULT, MOD_BOLD)
}

public func styleInput(): RichStyle {
    RichStyle(COLOR_WHITE, COLOR_DEFAULT, MOD_BOLD)
}

public func styleInputCursor(): RichStyle {
    RichStyle(COLOR_WHITE, COLOR_DEFAULT, MOD_UNDERLINED)
}

public func styleBodyStrong(): RichStyle {
    RichStyle(COLOR_WHITE, COLOR_DEFAULT, MOD_BOLD)
}

public func styleInfo(): RichStyle {
    RichStyle(COLOR_LIGHT_BLUE, COLOR_DEFAULT, MOD_BOLD)
}

public func styleSuccess(): RichStyle {
    RichStyle(COLOR_LIGHT_GREEN, COLOR_DEFAULT, MOD_BOLD)
}

public func styleWarning(): RichStyle {
    RichStyle(COLOR_YELLOW, COLOR_DEFAULT, MOD_BOLD)
}

public func styleErrorText(): RichStyle {
    RichStyle(COLOR_LIGHT_RED, COLOR_DEFAULT, MOD_BOLD)
}

public func styleDanger(): RichStyle {
    RichStyle(COLOR_RED, COLOR_DEFAULT, MOD_BOLD)
}

public func styleMuted(): RichStyle {
    RichStyle(COLOR_DARK_GRAY, COLOR_DEFAULT, 0)
}

public func styleSelected(): RichStyle {
    RichStyle(COLOR_LIGHT_CYAN, COLOR_DEFAULT, MOD_BOLD)
}
