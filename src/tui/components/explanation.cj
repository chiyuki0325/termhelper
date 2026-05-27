package termhelper.tui.components

import termhelper.types.*

public func renderExplanation(data: CommandData): String {
    var out = sectionTitle("分解说明")
    if (data.explanation.breakdown.size == 0) {
        return out + emptyState("模型没有提供分解说明。")
    }
    for (item in data.explanation.breakdown) {
        out += field(item.component, item.explanation)
    }
    out
}
