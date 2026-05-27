package termhelper.tui.components

import termhelper.types.*

public func renderOverlayPanel(data: PtyOverlayData): String {
    var out = "PTY 浮层\n"
    out += "模式: ${ptyModeText(data.mode)}  轮次: ${data.roundCount}/${data.maxRounds}\n"
    match (data.llmDecision) {
        case Some(v) => out += "决策: ${v}\n"
        case None => ()
    }
    match (data.pendingWrite) {
        case Some(v) => out += "待写入: ${v}\n"
        case None => ()
    }
    match (data.pendingReason) {
        case Some(v) => out += "原因: ${v}\n"
        case None => ()
    }
    out
}

func ptyModeText(mode: PtyMode): String {
    match (mode) {
        case PtyMode.Confirm => "确认"
        case PtyMode.FullAuto => "全自动"
    }
}
