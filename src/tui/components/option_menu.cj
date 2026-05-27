package termhelper.tui.components

import std.collection.*

public class MenuItem {
    public let key: String
    public let label: String

    public init(key: String, label: String) {
        this.key = key
        this.label = label
    }
}

public func renderOptionMenu(items: ArrayList<MenuItem>, selected: Int64): String {
    var out = sectionTitle("操作")
    for (i in 0..items.size) {
        let prefix = if (i == selected) { "  > " } else { "    " }
        out += prefix + items[i].label + "\n"
    }
    out
}
