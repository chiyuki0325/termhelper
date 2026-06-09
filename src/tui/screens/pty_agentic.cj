package termhelper.tui.screens

import termhelper.types.*
import termhelper.i18n.*
import termhelper.tui.components.*
import std.collection.*

// ═══════════════════════════════════════════════════════════════
// PTY Agentic 屏 — 阶段 6
// 全屏 PTY Cell→Span 渲染为底层 + overlay 面板浮动在上层
// ═══════════════════════════════════════════════════════════════

/// styled 版 PTY agentic 屏渲染（用于降级/纯文本场景）
/// 注意：AnsiText widget 模式下，终端输出由 rendering 层独立处理，
/// 此函数只渲染 overlay + 交互控制。
public func styledPtyAgentic(
    handle: Int64,
    command: String,
    rawBytes: ArrayList<UInt8>,
    overlay: PtyOverlayData,
    ptyState: String,
    scrollOffset: Int64,
    maxScroll: Int64,
    userInput: String,
    sensitiveInput: Bool
): Unit {
    let _ = rawBytes.size
    let _ = scrollOffset
    let _ = maxScroll

    // 标题行
    richTextSpan(handle, uiText("screen_pty"), styleTitle())
    let modeLabel = match (overlay.mode) {
        case PtyMode.FullAuto => uiText("pty_full_auto")
        case PtyMode.Confirm => uiText("pty_confirm")
    }
    richTextSpan(handle, "  ${uiText("overlay_mode")}: " + modeLabel, styleInfo())
    richTextSpan(handle, "  ${uiText("overlay_round")}: ${overlay.roundCount}/${overlay.maxRounds}", styleMuted())
    let statusLabel = ptyStateLabel(ptyState)
    richTextSpan(handle, "  [" + statusLabel + "]", ptyStatusStyle(ptyState))
    richTextLine(handle)
    richTextLine(handle)

    // 命令
    richTextLine(handle, uiText("section_command"), styleSection())
    richTextSpan(handle, "  $ ", styleMuted())
    richTextLine(handle, command, styleCommand())
    richTextLine(handle)

    // 终端输出区域 — 由外部 AnsiText widget 渲染

    // 分隔线 + 浮层面板
    richTextLine(handle)
    styledOverlayPanel(handle, overlay, ptyState, overlay.tokenInput, overlay.tokenOutput)

    // 用户输入区（AwaitingUserInput 状态）
    if (ptyState == "awaiting_input") {
        richTextLine(handle)
        let prompt = if (sensitiveInput) {
            uiText("pty_sensitive_input")
        } else {
            uiText("pty_input_prompt")
        }
        let displayInput = if (sensitiveInput) {
            ptyMaskedInput(userInput)
        } else {
            userInput
        }
        richTextSpan(handle, "  " + prompt, styleInfo())
        richTextLine(handle, displayInput, styleInput())
    }

    // 确认按钮提示（AwaitingConfirm 状态）
    if (ptyState == "awaiting_confirm") {
        richTextLine(handle)
        richTextSpan(handle, "  [Enter] ", styleSuccess())
        richTextSpan(handle, uiText("pty_confirm_write"), styleDefault())
        richTextSpan(handle, "  [D] ", styleErrorText())
        richTextSpan(handle, uiText("pty_deny"), styleDefault())
        richTextSpan(handle, "  [A] ", styleInfo())
        richTextSpan(handle, uiText("pty_switch_auto"), styleDefault())
    }

    // 轮次上限按钮提示
    if (ptyState == "round_limit") {
        richTextLine(handle)
        richTextSpan(handle, "  [Enter] ", styleSuccess())
        richTextSpan(handle, uiText("pty_continue"), styleDefault())
        richTextSpan(handle, "  [I] ", styleErrorText())
        richTextSpan(handle, uiText("pty_deny"), styleDefault())
        richTextSpan(handle, "  [M] ", styleInfo())
        richTextSpan(handle, uiText("pty_manual"), styleDefault())
    }

    // 键位提示
    richTextLine(handle)
    let keys = ptyKeysForState(ptyState)
    richTextSpan(handle, keys, if (ptyState == "finished") { styleSuccess() } else { styleMuted() })
}

// ═══════════════════════════════════════════════════════════════
// 降级渲染（纯文本）
// ═══════════════════════════════════════════════════════════════

/// 纯文本版 PTY agentic 屏渲染（降级兼容）
public func renderPtyAgentic(
    command: String,
    output: String,
    overlay: PtyOverlayData,
    ptyState: String,
    scrollOffset: Int64,
    userInput: String,
    sensitiveInput: Bool
): String {
    var out = screenHeader(uiText("screen_pty"), ptyStateLabel(ptyState))
    out += sectionTitle(uiText("section_command"))
    out += codeBlock(command)
    out += sectionTitle(uiText("pty_section_terminal"))
    if (output.size == 0) {
        out += emptyState(uiText("pty_waiting_output"))
    } else {
        let lines = output.split("\n")
        let visibleRows: Int64 = 15
        let startLine = ptyMax(0, ptyMin(scrollOffset, ptyMax(0, lines.size - visibleRows)))
        let endLine = ptyMin(startLine + visibleRows, lines.size)
        for (i in startLine..endLine) {
            out += "  " + lines[i] + "\n"
        }
    }
    out += "\n"
    out += renderOverlayPanel(overlay)
    if (ptyState == "awaiting_input") {
        let prompt = if (sensitiveInput) {
            uiText("pty_sensitive_input")
        } else {
            uiText("pty_input_prompt")
        }
        out += prompt + (if (sensitiveInput) { ptyMaskedInput(userInput) } else { userInput }) + "\n"
    }
    out += keyBar(ptyKeysForState(ptyState))
    out
}

// ── 辅助 ──

func ptyStateLabel(state: String): String {
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

func ptyKeysForState(state: String): String {
    match (state) {
        case "awaiting_confirm" => uiText("keys_pty_awaiting_confirm")
        case "awaiting_input" => uiText("keys_pty_awaiting_input")
        case "round_limit" => uiText("keys_pty_round_limit")
        case "finished" => uiText("keys_pty_done")
        case "interrupted" => uiText("keys_pty_interrupted")
        case _ => uiText("keys_pty_default")
    }
}

func ptyStatusStyle(state: String): RichStyle {
    match (state) {
        case "finished" => styleSuccess()
        case "interrupted" => styleErrorText()
        case _ => styleWarning()
    }
}

func ptyMaskedInput(current: String): String {
    var out = ""
    for (_ in current.runes()) { out += "*" }
    out
}

func ptyMax(a: Int64, b: Int64): Int64 { if (a > b) { a } else { b } }
func ptyMin(a: Int64, b: Int64): Int64 { if (a < b) { a } else { b } }
