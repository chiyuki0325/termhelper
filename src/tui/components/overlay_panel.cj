package termhelper.tui.components

import termhelper.types.*
import termhelper.i18n.*

// ═══════════════════════════════════════════════════════════════
// PTY Overlay 浮动面板组件
// 阶段 5: 纯文本渲染
// 阶段 6: 升级为 ratatui styled 渲染
// ═══════════════════════════════════════════════════════════════

/// 纯文本版叠加面板（阶段 5 兼容）
public func renderOverlayPanel(data: PtyOverlayData): String {
    var out = uiText("overlay_title") + "\n"
    out += "${uiText("overlay_mode")}: ${ptyModeText(data.mode)}  ${uiText("overlay_round")}: ${data.roundCount}/${data.maxRounds}\n"
    out += "${uiText("pty_tokens_used")}: ${formatTokenUsage(data.tokenInput, data.tokenOutput)}\n"
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

/// styled 版叠加面板 — 向给定的 ratatui rich text widget 渲染浮动面板行
public func styledOverlayPanel(handle: Int64, data: PtyOverlayData, state: String, tokenInput: Int64, tokenOutput: Int64): Unit {
    // 面板标题行
    richTextLine(handle, "── " + uiText("pty_overlay_title") + " ──", styleSection())

    // 模式 + 轮次 + Token
    let modeText = ptyModeText(data.mode)
    let statusText = ptyStatusLabel(state)
    var infoLine = "  ${uiText("overlay_mode")}: ${modeText}"
    infoLine += "  ${uiText("overlay_round")}: ${data.roundCount}/${data.maxRounds}"
    infoLine += "  ${uiText("pty_tokens_used")}: ${formatTokenUsage(tokenInput, tokenOutput)}"
    infoLine += "  [${statusText}]"
    richTextLine(handle, infoLine, styleMuted())

    // LLM 决策
    match (data.llmDecision) {
        case Some(decision) =>
            richTextSpan(handle, "  ${uiText("overlay_decision")}: ", styleMuted())
            richTextLine(handle, decision, styleInfo())
        case None => ()
    }

    // 待写入内容
    match (data.pendingWrite) {
        case Some(content) =>
            richTextSpan(handle, "  ${uiText("overlay_pending_write")}: ", styleMuted())
            richTextLine(handle, content, styleCommand())
        case None => ()
    }

    // 理由
    match (data.pendingReason) {
        case Some(reason) =>
            richTextSpan(handle, "  ${uiText("overlay_reason")}: ", styleMuted())
            richTextLine(handle, reason, styleDefault())
        case None => ()
    }
}

// ── 辅助 ──

func ptyModeText(mode: PtyMode): String {
    match (mode) {
        case PtyMode.Confirm => uiText("pty_confirm")
        case PtyMode.FullAuto => uiText("pty_full_auto")
    }
}

func ptyStatusLabel(state: String): String {
    match (state) {
        case "waiting" => uiText("pty_status_waiting")
        case "llm_decision" => uiText("pty_status_llm_decision")
        case "awaiting_confirm" => uiText("pty_status_awaiting_confirm")
        case "awaiting_input" => uiText("pty_status_awaiting_input")
        case "throttled" => uiText("pty_status_throttled")
        case "round_limit" => uiText("pty_status_round_limit")
        case "finished" => uiText("pty_status_finished")
        case "interrupted" => uiText("pty_status_interrupted")
        case _ => state
    }
}

public func formatTokenUsage(input: Int64, output: Int64): String {
    "${formatTokenCount(input)}+${formatTokenCount(output)}"
}

public func formatTokenCount(value: Int64): String {
    if (value < 1000) {
        return "${value}"
    }
    if (value < 1000000) {
        return formatCompactToken(value, 1000, "K")
    }
    formatCompactToken(value, 1000000, "M")
}

func formatCompactToken(value: Int64, unit: Int64, suffix: String): String {
    let whole = value / unit
    let tenth = (value % unit) * 10 / unit
    if (tenth == 0 || whole >= 100) {
        "${whole}${suffix}"
    } else {
        "${whole}.${tenth}${suffix}"
    }
}
