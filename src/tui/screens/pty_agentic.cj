package termhelper.tui.screens

import ratatui.core.*
import termhelper.types.*
import termhelper.infra.*
import termhelper.i18n.*
import termhelper.tui.components.*
import std.collection.*

// ═══════════════════════════════════════════════════════════════
// PTY Agentic 屏 — 阶段 6
// 全屏 PTY Cell→Span 渲染为底层 + overlay 面板浮动在上层
// ═══════════════════════════════════════════════════════════════

// ── 本地颜色/修饰常量（styled_text.cj 中为包内私有）──
let PTY_COLOR_DEFAULT: Int32 = 0
let PTY_MOD_BOLD: Int32 = 1
let PTY_MOD_UNDERLINED: Int32 = 8

/// styled 版 PTY agentic 屏渲染（从 TerminalBuffer 的 Cell 网格渲染）
public func styledPtyAgentic(
    handle: Int64,
    command: String,
    terminalBuf: ?TerminalBuffer,
    overlay: PtyOverlayData,
    ptyState: String,
    scrollOffset: Int64,
    maxScroll: Int64,
    userInput: String,
    sensitiveInput: Bool
): Unit {
    // 标题行
    richTextSpan(handle, uiText("screen_pty"), styleTitle())
    let modeLabel = match (overlay.mode) {
        case PtyMode.FullAuto => uiText("pty_full_auto")
        case PtyMode.Confirm => uiText("pty_confirm")
    }
    richTextSpan(handle, "  ${uiText("overlay_mode")}: " + modeLabel, styleInfo())
    richTextSpan(handle, "  ${uiText("overlay_round")}: ${overlay.roundCount}/${overlay.maxRounds}", styleMuted())
    let statusLabel = ptyStateLabel(ptyState)
    richTextSpan(handle, "  [" + statusLabel + "]", styleWarning())
    richTextLine(handle)
    richTextLine(handle)

    // 命令
    richTextLine(handle, uiText("section_command"), styleSection())
    richTextSpan(handle, "  $ ", styleMuted())
    richTextLine(handle, command, styleCommand())
    richTextLine(handle)

    // 终端输出区域 — Cell→Span ANSI 渲染
    richTextLine(handle, uiText("pty_section_terminal"), styleSection())
    match (terminalBuf) {
        case Some(buf) =>
            renderTerminalCells(handle, buf, scrollOffset, maxScroll)
        case None =>
            richTextLine(handle, "  " + uiText("pty_waiting_output"), styleMuted())
    }

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
    richTextSpan(handle, keys, styleMuted())
}

// ── Cell→Span 渲染 ──

/// 从 TerminalBuffer 的 Cell 网格渲染可见行，每个 Cell → ratatui Span
public func renderTerminalCells(handle: Int64, buf: TerminalBuffer, scrollOffset: Int64, maxScroll: Int64): Unit {
    let totalRows = buf.rows
    let visibleRows: Int64 = 12
    let startRow = if (scrollOffset > 0) { scrollOffset } else { 0 }
    let endRow = ptyMin(startRow + visibleRows, totalRows)

    if (startRow > 0) {
        richTextLine(handle, "  ... (${startRow} rows above) ...", styleMuted())
    }

    for (r in startRow..endRow) {
        let row = buf.getRow(r)
        renderCellRow(handle, row)
        richTextLine(handle)
    }

    if (endRow < totalRows) {
        richTextLine(handle, "  ... (${totalRows - endRow} rows below) ...", styleMuted())
    }
}

/// 将一行 Cell 渲染为 ratatui styled spans
/// 优化：相同样式的连续 Cell 合并为一个 span，减少 FFI 调用
func renderCellRow(handle: Int64, row: ArrayList<Cell>): Unit {
    if (row.size == 0) { return }

    richTextSpan(handle, "  ", styleDefault())

    var runStart: Int64 = 0
    var currentStyle = cellToStyle(row[0])
    var currentText = ""

    for (c in 0..row.size) {
        let cell = row[c]
        let style = cellToStyle(cell)
        let ch = cellChar(cell)

        if (!stylesEqual(style, currentStyle)) {
            // 输出当前 run
            richTextSpan(handle, currentText, currentStyle)
            currentText = ch
            currentStyle = style
        } else {
            currentText += ch
        }
    }

    // 输出最后一个 run
    if (currentText.size > 0) {
        richTextSpan(handle, currentText, currentStyle)
    }
}

/// Cell 字符 → 可打印字符串
func cellChar(cell: Cell): String {
    if (cell.char <= r' ') {
        " "  // 控制字符显示为空格
    } else {
        String(cell.char)
    }
}

/// Cell 属性 → RichStyle
func cellToStyle(cell: Cell): RichStyle {
    let fg = ansiColorToRata(cell.fg, false)
    let bg = ansiColorToRata(cell.bg, true)
    var mods: Int32 = 0
    if (cell.attrs.bold) { mods += PTY_MOD_BOLD }
    if (cell.attrs.underline) { mods += PTY_MOD_UNDERLINED }
    // 反色：交换前景色和背景色
    if (cell.attrs.reverse) {
        RichStyle(bgColor(cell.bg), bgColor(cell.fg), mods)
    } else {
        RichStyle(fg, bg, mods)
    }
}

/// ANSI 调色板索引 → ratatui 颜色码
func ansiColorToRata(color: AnsiColor, isBg: Bool): Int32 {
    if (!isBg && color.idx == -1) { return PTY_COLOR_DEFAULT }
    if (isBg && color.idx == -1) { return PTY_COLOR_DEFAULT }
    if (color.idx == -2) { return PTY_COLOR_DEFAULT } // 24-bit 暂不支持

    let idx = color.idx
    if (color.isBright) {
        // Bright (8-15) → ratatui 亮色
        let brightIdx: Int32 = Int32(idx) + 8
        if (isBg) { return brightIdx + 1 }
        return brightIdx
    }

    // 标准 ANSI palette (0-7)
    let baseColor: Int32 = if (idx >= 0 && idx <= 7) { Int32(idx) } else { PTY_COLOR_DEFAULT }
    if (isBg) { return baseColor + 1 }
    baseColor
}

func bgColor(color: AnsiColor): Int32 {
    if (color.idx == -1) { return PTY_COLOR_DEFAULT }
    ansiColorToRata(color, true)
}

func stylesEqual(a: RichStyle, b: RichStyle): Bool {
    a.fg == b.fg && a.bg == b.bg && a.modifiers == b.modifiers
}

// ═══════════════════════════════════════════════════════════════
// 降级渲染（纯文本 / 无 TerminalBuffer 时使用）
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
        case "finished" | "interrupted" => uiText("keys_exit")
        case _ => uiText("keys_pty_default")
    }
}

func ptyMaskedInput(current: String): String {
    var out = ""
    for (_ in current.runes()) { out += "*" }
    out
}

func ptyMax(a: Int64, b: Int64): Int64 { if (a > b) { a } else { b } }
func ptyMin(a: Int64, b: Int64): Int64 { if (a < b) { a } else { b } }
