package termhelper.tui.components

public class TextInput {
    public var value: String = ""
    public var sensitive: Bool = false

    public init() {}

    public func append(ch: Rune): Unit {
        value += String(ch)
    }

    public func backspace(): Unit {
        if (value.size > 0) {
            value = value[0..value.size - 1]
        }
    }

    public func render(): String {
        if (sensitive) {
            var hidden = ""
            for (_ in 0..value.size) {
                hidden += "*"
            }
            hidden
        } else {
            value
        }
    }
}
