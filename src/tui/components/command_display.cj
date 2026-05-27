package termhelper.tui.components

import termhelper.types.*

public func renderCommandDisplay(data: CommandData): String {
    var out = sectionTitle("命令")
    out += codeBlock(data.command)
    if (data.explanation.summary.size > 0) {
        out += field("摘要", data.explanation.summary)
    }
    out
}
