package termhelper.tui.components

import termhelper.types.*
import termhelper.i18n.*

public func renderOverlayPanel(data: PtyOverlayData): String {
    var out = uiText("overlay_title") + "\n"
    out += "${uiText("overlay_mode")}: ${ptyModeText(data.mode)}  ${uiText("overlay_round")}: ${data.roundCount}/${data.maxRounds}\n"
    match (data.llmDecision) {
        case Some(v) => out += "${uiText("overlay_decision")}: ${v}\n"
        case None => ()
    }
    match (data.pendingWrite) {
        case Some(v) => out += "${uiText("overlay_pending_write")}: ${v}\n"
        case None => ()
    }
    match (data.pendingReason) {
        case Some(v) => out += "${uiText("overlay_reason")}: ${v}\n"
        case None => ()
    }
    out
}

func ptyModeText(mode: PtyMode): String {
    match (mode) {
        case PtyMode.Confirm => uiText("pty_confirm")
        case PtyMode.FullAuto => uiText("pty_full_auto")
    }
}
