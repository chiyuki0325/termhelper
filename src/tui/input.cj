package termhelper.tui

import ratatui.core.*

public enum Action {
    | NavigateUp
    | NavigateDown
    | NavigateLeft
    | NavigateRight
    | Confirm
    | Back
    | Run
    | Copy
    | Modify
    | Interrupt
    | Toggle
    | ScrollUp
    | ScrollDown
    | PageUp
    | PageDown
    | ScrollTop
    | ScrollBottom
    | Submit
    | Backspace
    | TextInput(String)
    | TerminalResize(UInt16, UInt16)
    | Noop
}

public func mapEvent(eventHandle: Int64): ?Action {
    if (eventIsResize(eventHandle)) {
        let (w, h) = eventGetResize(eventHandle)
        return Some(Action.TerminalResize(w, h))
    }
    if (!eventIsKey(eventHandle)) {
        if (eventIsMouse(eventHandle)) {
            let mouseCode = eventGetMouseCode(eventHandle)
            if (mouseCode == 1) {
                return Some(Action.ScrollUp)
            }
            if (mouseCode == 2) {
                return Some(Action.ScrollDown)
            }
            return Some(Action.Noop)
        }
        if (eventIsQuit(eventHandle)) {
            return Some(Action.Back)
        }
        return None
    }

    let code = eventGetKeyCode(eventHandle)
    let ch = eventGetKeyChar(eventHandle)
    let text = eventGetKeyText(eventHandle)

    if (text.size == 1 && ch >= Int8(32) && ch <= Int8(126)) {
        if (ch == Int8(114) || ch == Int8(82)) {
            return Some(Action.Run)
        }
        if (ch == Int8(99) || ch == Int8(67)) {
            return Some(Action.Copy)
        }
        if (ch == Int8(109) || ch == Int8(77)) {
            return Some(Action.Modify)
        }
        if (ch == Int8(32)) {
            return Some(Action.Toggle)
        }
        return Some(Action.TextInput(text))
    }

    if (text.size > 0) {
        return Some(Action.TextInput(text))
    }

    if (ch == Int8(27) || code == 27) {
        return Some(Action.Back)
    }
    if (ch == Int8(3) || code == 3) {
        return Some(Action.Interrupt)
    }
    if (code == 13 || code == 10 || code == 1 || ch == Int8(10) || ch == Int8(13)) {
        return Some(Action.Confirm)
    }
    if (code == 8 || code == 127 || ch == Int8(8) || ch == Int8(127)) {
        return Some(Action.Backspace)
    }
    if (code == 4 || code == 1001) {
        return Some(Action.NavigateUp)
    }
    if (code == 5 || code == 1002) {
        return Some(Action.NavigateDown)
    }
    if (code == 2 || code == 1003) {
        return Some(Action.NavigateLeft)
    }
    if (code == 3 || code == 1004) {
        return Some(Action.NavigateRight)
    }
    if (code == 1005) {
        return Some(Action.PageUp)
    }
    if (code == 1006) {
        return Some(Action.PageDown)
    }
    if (code == 1007) {
        return Some(Action.ScrollTop)
    }
    if (code == 1008) {
        return Some(Action.ScrollBottom)
    }

    Some(Action.Noop)
}
