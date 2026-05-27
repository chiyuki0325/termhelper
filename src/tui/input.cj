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
    | Submit
    | Backspace
    | TextChar(Rune)
    | Noop
}

public func mapEvent(eventHandle: Int64): ?Action {
    if (!eventIsKey(eventHandle)) {
        if (eventIsQuit(eventHandle)) {
            return Some(Action.Back)
        }
        return None
    }

    let code = eventGetKeyCode(eventHandle)
    let ch = eventGetKeyChar(eventHandle)

    if (ch >= Int8(32) && ch <= Int8(126)) {
        if (ch == Int8(114) || ch == Int8(82)) { return Some(Action.Run) }
        if (ch == Int8(99) || ch == Int8(67)) { return Some(Action.Copy) }
        if (ch == Int8(109) || ch == Int8(77)) { return Some(Action.Modify) }
        if (ch == Int8(32)) { return Some(Action.Toggle) }
        return Some(Action.TextChar(Rune(Int32(ch))))
    }

    if (ch == Int8(27) || code == 27) { return Some(Action.Back) }
    if (ch == Int8(3) || code == 3) { return Some(Action.Interrupt) }
    if (code == 13 || code == 10 || code == 1 || ch == Int8(10) || ch == Int8(13)) { return Some(Action.Confirm) }
    if (code == 8 || code == 127 || ch == Int8(8) || ch == Int8(127)) { return Some(Action.Backspace) }
    if (code == 4 || code == 1001) { return Some(Action.NavigateUp) }
    if (code == 5 || code == 1002) { return Some(Action.NavigateDown) }
    if (code == 2 || code == 1003) { return Some(Action.NavigateLeft) }
    if (code == 3 || code == 1004) { return Some(Action.NavigateRight) }

    Some(Action.Noop)
}
