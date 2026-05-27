package termhelper.tui.components

import termhelper.types.*
import termhelper.i18n.*

public func renderExplanation(data: CommandData): String {
    var out = sectionTitle(uiText("section_breakdown"))
    if (data.explanation.breakdown.size == 0) {
        return out + emptyState(uiText("no_breakdown"))
    }
    for (item in data.explanation.breakdown) {
        out += field(item.component, item.explanation)
    }
    out
}
