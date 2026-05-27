package termhelper.tui.components

import termhelper.types.*

public func renderOverlayPanel(data: PtyOverlayData): String {
    var out = "PTY overlay\n"
    out += "Mode: ${ptyModeText(data.mode)}  Round: ${data.roundCount}/${data.maxRounds}\n"
    match (data.llmDecision) {
        case Some(v) => out += "Decision: ${v}\n"
        case None => ()
    }
    match (data.pendingWrite) {
        case Some(v) => out += "Pending write: ${v}\n"
        case None => ()
    }
    match (data.pendingReason) {
        case Some(v) => out += "Reason: ${v}\n"
        case None => ()
    }
    out
}

func ptyModeText(mode: PtyMode): String {
    match (mode) {
        case PtyMode.Confirm => "confirm"
        case PtyMode.FullAuto => "full-auto"
    }
}
