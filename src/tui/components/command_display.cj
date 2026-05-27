package termhelper.tui.components

import termhelper.types.*
import termhelper.i18n.*

public func renderCommandDisplay(data: CommandData): String {
    var out = sectionTitle(uiText("section_command"))
    out += codeBlock(data.command)
    if (data.explanation.summary.size > 0) {
        out += field(uiText("field_summary"), data.explanation.summary)
    }
    out
}
