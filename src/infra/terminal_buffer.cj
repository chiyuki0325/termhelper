package termhelper.infra

// ═══════════════════════════════════════════════════════════════
// 虚拟终端缓冲区 + ANSI 转义序列解析器
// 阶段 2：核心数据结构 + ANSI SGR/光标/清屏解析
// 阶段 6：对接 TUI 全屏渲染 (Cell → ratatui Span)
// ═══════════════════════════════════════════════════════════════

import std.collection.*

// ── 特殊字符常量 ──

let RUNE_ESC = Rune(27)
let RUNE_BS  = Rune(8)

// ── 颜色类型 ──

/// ANSI 3/4-bit 调色板索引
public struct AnsiColor {
    public let idx: Int64       // 0-15, -1 = default
    public let isBright: Bool

    public init(idx: Int64, isBright: Bool) { this.idx = idx; this.isBright = isBright }

    public static func defaultFg(): AnsiColor { AnsiColor(-1, false) }
    public static func defaultBg(): AnsiColor { AnsiColor(-1, false) }
}

// ── 字符属性 ──

/// 单元格的文本属性
public struct CellAttrs {
    public var bold: Bool
    public var underline: Bool
    public var reverse: Bool
    public var dim: Bool
    public var italic: Bool
    public var blink: Bool

    public init() {
        this.bold = false; this.underline = false; this.reverse = false
        this.dim = false; this.italic = false; this.blink = false
    }

    /// 重置所有属性为默认
    public func reset(): CellAttrs {
        CellAttrs()
    }
}

// ── 单元格 ──

/// 虚拟终端的一个字符单元格
public struct Cell {
    public var char: Rune       // 字符
    public var fg: AnsiColor    // 前景色
    public var bg: AnsiColor    // 背景色
    public var attrs: CellAttrs // 属性

    public init(ch: Rune) {
        this.char = ch
        this.fg = AnsiColor.defaultFg()
        this.bg = AnsiColor.defaultBg()
        this.attrs = CellAttrs()
    }

    public static func empty(): Cell { Cell(r' ') }
}

// ── 光标状态 ──

/// 光标位置（class：需要引用语义，支持原地修改）
public class Cursor {
    public var row: Int64   // 0-indexed
    public var col: Int64

    public init(row: Int64, col: Int64) { this.row = row; this.col = col }
    public static func home(): Cursor { Cursor(0, 0) }

    /// 带边界限制的设置（class 方法，直接修改）
    public func clamp(maxRow: Int64, maxCol: Int64): Unit {
        var r = row
        var c = col
        if (r < 0) { r = 0 }
        if (r >= maxRow) { r = maxRow - 1 }
        if (c < 0) { c = 0 }
        if (c >= maxCol) { c = maxCol - 1 }
        Cursor(r, c)
    }
}

// ── 终端缓冲区 ──

/// 虚拟终端缓冲区（包含活跃屏幕区域 + 滚动回视区）
public class TerminalBuffer {
    public var rows: Int64           // 活跃行数 (= 真实终端高度)
    public var cols: Int64           // 活跃列数 (= 真实终端宽度)
    public var cursor: Cursor        // 当前光标位置
    public var savedCursor: Cursor   // 保存的光标位置

    // 活跃屏幕（rows × cols 网格）
    private var grid: ArrayList<ArrayList<Cell>>

    // 当前绘制属性（新字符使用）
    var currentFg: AnsiColor
    var currentBg: AnsiColor
    var currentAttrs: CellAttrs

    // 滚动回视区
    private var scrollback: ArrayList<ArrayList<Cell>>

    // ANSI 解析状态
    private var ansiBuf: String
    private var ansiParams: ArrayList<Int64>
    private var inEscape: Bool
    private var inCsi: Bool
    private var csiPrivate: Bool

    // UTF-8 解码状态（多字节字符累积）
    private var utf8Buf: Array<UInt8>
    private var utf8Expected: Int64   // 当前多字节序列还需几个续接字节
    private var utf8Total: Int64      // 当前序列总长度

    public init(rows: Int64, cols: Int64) {
        this.rows = rows
        this.cols = cols
        this.cursor = Cursor.home()
        this.savedCursor = Cursor.home()

        this.grid = ArrayList<ArrayList<Cell>>(rows)
        for (r in 0..rows) {
            let row = ArrayList<Cell>(cols)
            for (c in 0..cols) { row.add(Cell.empty()) }
            this.grid.add(row)
        }

        this.currentFg = AnsiColor.defaultFg()
        this.currentBg = AnsiColor.defaultBg()
        this.currentAttrs = CellAttrs()

        this.scrollback = ArrayList<ArrayList<Cell>>()
        this.ansiBuf = ""
        this.ansiParams = ArrayList<Int64>()
        this.inEscape = false
        this.inCsi = false
        this.csiPrivate = false
        this.utf8Buf = Array<UInt8>(4, repeat: 0)
        this.utf8Expected = 0
        this.utf8Total = 0
    }

    // ── 公开接口 ──

    /// 获取某行（活跃区域，0-indexed）
    public func getRow(row: Int64): ArrayList<Cell> { grid[row] }

    /// 获取滚动回视区行数
    public func scrollbackSize(): Int64 { scrollback.size }

    /// 获取滚动回视区某行
    public func getScrollbackRow(idx: Int64): ArrayList<Cell> { scrollback[idx] }

    /// 变更终端大小（保留内容，裁剪或新增空行）
    public func resize(newRows: Int64, newCols: Int64): Unit {
        // 裁剪/扩展列
        for (r in 0..grid.size) {
            let row = grid[r]
            while (row.size < newCols) { row.add(Cell.empty()) }
            while (row.size > newCols) { row.remove(at:row.size - 1) }
        }
        // 裁剪/扩展行
        while (grid.size < newRows) {
            let row = ArrayList<Cell>(newCols)
            for (c in 0..newCols) { row.add(Cell.empty()) }
            grid.add(row)
        }
        while (grid.size > newRows) {
            let removed = grid[0]
            grid.remove(at:0)
            scrollback.add(removed)
        }
        this.rows = newRows
        this.cols = newCols
        cursor.clamp(rows, cols)
    }

    /// 重置所有单元格和属性
    public func fullReset(): Unit {
        for (r in 0..grid.size) {
            for (c in 0..grid[r].size) {
                grid[r][c] = Cell.empty()
            }
        }
        cursor = Cursor.home()
        currentFg = AnsiColor.defaultFg()
        currentBg = AnsiColor.defaultBg()
        currentAttrs.reset()
        scrollback.clear()
    }

    /// 获取可见区域内容的纯文本表示（用于发送给 LLM）
    public func toPlainText(): String {
        var result = ""
        for (r in 0..grid.size) {
            for (c in 0..grid[r].size) {
                let ch = grid[r][c].char
                if (ch != r'\0') {
                    result += String(ch)
                }
            }
            result += "\n"
        }
        result
    }

    // ── 输入处理：逐字节喂入 PTY 输出 ──

    /// 处理一字节 PTY 输出（含 UTF-8 多字节解码）
    public func processByte(b: UInt8): Unit {
        // ESC 优先处理（无论 UTF-8 状态如何）
        if (b == 27) {
            // 如果正在累积 UTF-8 序列，先丢弃（不完整序列）
            utf8Expected = 0
            inEscape = true
            ansiBuf = ""
            return
        }

        // ANSI CSI 序列处理（非 UTF-8 文本）
        if (inCsi) {
            processCsiByte(Rune(Int32(b)))
            return
        }
        if (inEscape) {
            if (b == b'[') {
                inEscape = false
                inCsi = true
                ansiBuf = ""
                ansiParams.clear()
                csiPrivate = false
            } else {
                inEscape = false
                processEscChar(Rune(Int32(b)))
            }
            return
        }

        // UTF-8 多字节解码
        if (utf8Expected > 0) {
            // 续接字节：必须是 10xxxxxx
            if ((b & 0xC0) == 0x80) {
                let idx = utf8Total - utf8Expected
                utf8Buf[idx] = b
                utf8Expected -= 1
                if (utf8Expected == 0) {
                    // 序列完成，解码为 Rune
                    let arr = Array<UInt8>(utf8Total, repeat: 0)
                    for (i in 0..utf8Total) { arr[i] = utf8Buf[i] }
                    let s = String.fromUtf8(arr)
                    if (s.size > 0) {
                        let runes = s.toRuneArray()
                        if (runes.size > 0) {
                            putChar(runes[0])
                        }
                    }
                }
            } else {
                // 非续接字节，丢弃不完整序列，按新字节处理
                utf8Expected = 0
                processByte(b)
            }
            return
        }

        // 新字符开始
        if (b < 0x80) {
            // ASCII 单字节
            if (b >= 32) {  // 可见 ASCII（空格及以上）
                putChar(Rune(Int32(b)))
            } else if (b == 10) {  // \n
                putChar(r'\n')
            } else if (b == 13) {  // \r
                putChar(r'\r')
            } else if (b == 9) {   // \t
                putChar(r'\t')
            } else if (b == 8) {   // BS
                putChar(RUNE_BS)
            }
            // 其他控制字符忽略
        } else if ((b & 0xE0) == 0xC0) {
            // 2 字节序列: 110xxxxx
            utf8Buf[0] = b
            utf8Expected = 1
            utf8Total = 2
        } else if ((b & 0xF0) == 0xE0) {
            // 3 字节序列: 1110xxxx（CJK 常用）
            utf8Buf[0] = b
            utf8Expected = 2
            utf8Total = 3
        } else if ((b & 0xF8) == 0xF0) {
            // 4 字节序列: 11110xxx
            utf8Buf[0] = b
            utf8Expected = 3
            utf8Total = 4
        }
        // 非法字节（10xxxxxx 开头但无起始字节）忽略
    }

    /// 处理一批 PTY 输出
    public func processData(data: Array<UInt8>): Unit {
        for (b in data) { processByte(b) }
    }

    /// 处理字符串形式的 PTY 输出
    public func processString(s: String): Unit {
        let bytes = s.toArray()
        processData(bytes)
    }

    // ── 内部：字符写入 ──

    private func putChar(ch: Rune): Unit {
        if (ch == r'\n') {
            cursor.row += 1
            cursor.col = 0
            if (cursor.row >= rows) {
                scrollUp()
                cursor.row = rows - 1
            }
        } else if (ch == r'\r') {
            cursor.col = 0
        } else if (ch == r'\t') {
            // 制表符：跳到下个 8 的倍数列
            cursor.col = ((cursor.col / 8) + 1) * 8
            if (cursor.col >= cols) { cursor.col = cols - 1 }
        } else if (ch == RUNE_BS) { // BS
            if (cursor.col > 0) { cursor.col -= 1 }
        } else if (ch > r' ') {
            // 可见字符（ASCII + Unicode，包括中文等多字节字符）
            let w = charWidth(ch)
            // 双宽字符：确保从偶数列开始，否则前面补空格
            if (w == 2 && cursor.col % 2 != 0 && cursor.col + 2 <= cols) {
                if (cursor.row >= 0 && cursor.row < rows) {
                    grid[cursor.row][cursor.col] = Cell.empty()
                }
                cursor.col += 1
            }
            let fitsWidth = if (w == 2) { cursor.col + 2 <= cols } else { cursor.col < cols }
            if (cursor.row >= 0 && cursor.row < rows && cursor.col >= 0 && fitsWidth) {
                var cell = Cell(ch)
                cell.fg = currentFg
                cell.bg = currentBg
                cell.attrs = currentAttrs
                grid[cursor.row][cursor.col] = cell
            }
            // 双宽字符占两格：第二格放占位符
            if (w == 2 && cursor.col + 2 <= cols) {
                if (cursor.row >= 0 && cursor.row < rows) {
                    grid[cursor.row][cursor.col + 1] = Cell(Rune(0))
                }
            }
            cursor.col += w
            if (cursor.col >= cols) {
                cursor.col = 0
                cursor.row += 1
                if (cursor.row >= rows) {
                    scrollUp()
                    cursor.row = rows - 1
                }
            }
        }
    }

    /// 向上滚动一行（最顶行移入 scrollback）
    private func scrollUp(): Unit {
        let top = grid[0]
        scrollback.add(top)
        grid.remove(at:0)

        let newRow = ArrayList<Cell>(cols)
        for (c in 0..cols) { newRow.add(Cell.empty()) }
        grid.add(newRow)
    }

    // ── ESC 单字符序列 ──

    private func processEscChar(ch: Rune): Unit {
        // ESC c — 完全重置
        if (ch == r'c') { fullReset() }
    }

    // ── CSI 序列解析 ──

    private func processCsiByte(ch: Rune): Unit {
        if (ch >= r'0' && ch <= r'9') {
            ansiBuf += String(ch)
        } else if (ch == r';') {
            parseAnsiParam()
        } else if (ch == r'?') {
            csiPrivate = true
        } else {
            // 终结字符
            parseAnsiParam() // 解析最后一个参数
            executeCsiSequence(ch)
            inCsi = false
            csiPrivate = false
            ansiBuf = ""
            ansiParams.clear()
        }
    }

    private func parseAnsiParam(): Unit {
        if (ansiBuf.size > 0) {
            ansiParams.add(parseInt64(ansiBuf))
        } else {
            ansiParams.add(0) // 空参数 = 0
        }
        ansiBuf = ""
    }

    private func executeCsiSequence(ch: Rune): Unit {
        let defaultParam = if (ansiParams.size > 0) { ansiParams[0] } else { 0 }

        match (ch) {
            // Cursor Up / Down / Forward / Back
            case r'A' => cursor.row -= defaultParam; cursor.clamp(rows, cols)
            case r'B' => cursor.row += defaultParam; cursor.clamp(rows, cols)
            case r'C' => cursor.col += defaultParam; cursor.clamp(rows, cols)
            case r'D' => cursor.col -= defaultParam; cursor.clamp(rows, cols)

            // Cursor Position (行;列，1-indexed)
            case r'H' | r'f' =>
                let row = if (ansiParams.size >= 1 && ansiParams[0] > 0) { ansiParams[0] - 1 } else { 0 }
                let col = if (ansiParams.size >= 2 && ansiParams[1] > 0) { ansiParams[1] - 1 } else { 0 }
                cursor.row = row
                cursor.col = col
                cursor.clamp(rows, cols)

            // Cursor Next Line
            case r'E' =>
                cursor.row += defaultParam
                cursor.col = 0
                if (cursor.row >= rows) { scrollUp(); cursor.row = rows - 1 }

            // Erase in Display
            case r'J' =>
                if (defaultParam == 2) {
                    // 清屏 + 光标回原位
                    for (r in 0..grid.size) {
                        for (c in 0..grid[r].size) {
                            grid[r][c] = Cell.empty()
                        }
                    }
                    cursor = Cursor.home()
                } else if (defaultParam == 0) {
                    eraseFromCursor()
                } else if (defaultParam == 1) {
                    eraseToCursor()
                }

            // Erase in Line
            case r'K' =>
                if (defaultParam == 2) {
                    eraseLine()
                } else if (defaultParam == 0) {
                    eraseLineFromCursor()
                } else if (defaultParam == 1) {
                    eraseLineToCursor()
                }

            // SGR — Select Graphic Rendition
            case r'm' =>
                if (ansiParams.size == 0) {
                    currentAttrs = currentAttrs.reset()
                    currentFg = AnsiColor.defaultFg()
                    currentBg = AnsiColor.defaultBg()
                } else {
                    var i: Int64 = 0
                    while (i < ansiParams.size) {
                        let p = ansiParams[i]
                        if (p == 38 && i + 1 < ansiParams.size) {
                            // 扩展前景色
                            let mode = ansiParams[i + 1]
                            if (mode == 5 && i + 2 < ansiParams.size) {
                                // 256 色调色板 fg
                                // store extended color info (simplified: store index in idx)
                                currentFg = AnsiColor(ansiParams[i + 2], false)
                                i += 2
                            } else if (mode == 2 && i + 4 < ansiParams.size) {
                                // 24-bit 真彩色 fg (store R in idx as marker, G/B ignored for now)
                                // Full implementation would need RGB storage in AnsiColor
                                currentFg = AnsiColor(-2, false) // -2 = 24-bit marker
                                i += 4
                            }
                            i += 1
                        } else if (p == 48 && i + 1 < ansiParams.size) {
                            // 扩展背景色
                            let mode = ansiParams[i + 1]
                            if (mode == 5 && i + 2 < ansiParams.size) {
                                currentBg = AnsiColor(ansiParams[i + 2], false)
                                i += 2
                            } else if (mode == 2 && i + 4 < ansiParams.size) {
                                currentBg = AnsiColor(-2, false)
                                i += 4
                            }
                            i += 1
                        } else {
                            applySgrParam(p)
                        }
                        i += 1
                    }
                }

            // Scroll Up / Down
            case r'S' => for (j in 0..defaultParam) { scrollUp() }
            case r'T' => for (j in 0..defaultParam) { scrollDown() }

            // Insert Lines (IL) — CSI Ps L
            case r'L' => insertLines(defaultParam)
            // Delete Lines (DL) — CSI Ps M
            case r'M' => deleteLines(defaultParam)
            // Delete Characters (DCH) — CSI Ps P
            case r'P' => deleteChars(defaultParam)

            // Save / Restore cursor
            case r's' => savedCursor = Cursor(cursor.row, cursor.col)
            case r'u' => cursor = Cursor(savedCursor.row, savedCursor.col)

            case _ => () // 忽略不识别的序列
        }
    }

    private func applySgrParam(p: Int64): Unit {
        match (p) {
            case 0 => currentAttrs.reset(); currentFg = AnsiColor.defaultFg(); currentBg = AnsiColor.defaultBg()
            case 1 => currentAttrs.bold = true
            case 2 => currentAttrs.dim = true
            case 3 => currentAttrs.italic = true
            case 4 => currentAttrs.underline = true
            case 5 => currentAttrs.blink = true
            case 7 => currentAttrs.reverse = true
            case 22 => currentAttrs.bold = false; currentAttrs.dim = false
            case 23 => currentAttrs.italic = false
            case 24 => currentAttrs.underline = false
            case 25 => currentAttrs.blink = false
            case 27 => currentAttrs.reverse = false
            case _ where (p >= 30 && p <= 37) => currentFg = AnsiColor(p - 30, false)
            case 39 => currentFg = AnsiColor.defaultFg()
            case _ where (p >= 40 && p <= 47) => currentBg = AnsiColor(p - 40, false)
            case 49 => currentBg = AnsiColor.defaultBg()
            case _ where (p >= 90 && p <= 97) => currentFg = AnsiColor(p - 90, true)
            case _ where (p >= 100 && p <= 107) => currentBg = AnsiColor(p - 100, true)
            case _ => ()
        }
    }

    // ── 插入/删除行/字符 (#9) ──

    /// Insert Lines (IL) — CSI Ps L
    private func insertLines(count: Int64): Unit {
        let n = if (count < 1) { 1 } else { count }
        for (j in 0..n) {
            // 从底部开始，每行向下移动一行（光标行以下的内容）
            var r = rows - 1
            while (r > cursor.row) {
                copyRow(r, r - 1)  // grid[r] = grid[r-1] 的内容
                r -= 1
            }
            // 光标行清空
            for (c in 0..cols) { grid[cursor.row][c] = Cell.empty() }
        }
    }

    /// Delete Lines (DL) — CSI Ps M
    private func deleteLines(count: Int64): Unit {
        let n = if (count < 1) { 1 } else { count }
        for (j in 0..n) {
            // 从光标行开始，每行向上移动
            var r = cursor.row
            while (r < rows - 1) {
                copyRow(r, r + 1)
                r += 1
            }
            // 最后行清空
            for (c in 0..cols) { grid[rows - 1][c] = Cell.empty() }
        }
    }

    /// 复制一行内容（逐格复制，避免引用共享）
    private func copyRow(dst: Int64, src: Int64): Unit {
        for (c in 0..cols) {
            grid[dst][c] = grid[src][c]
        }
    }

    /// Delete Characters (DCH) — CSI Ps P
    /// 删除光标处 Ps 个字符，后续字符左移
    private func deleteChars(count: Int64): Unit {
        let n = if (count < 1) { 1 } else { count }
        let r = cursor.row
        let c = cursor.col
        // 将后续字符左移
        for (i in (c + n)..cols) {
            grid[r][i - n] = grid[r][i]
        }
        // 尾部填充空格
        for (i in (cols - n)..cols) {
            grid[r][i] = Cell.empty()
        }
    }

    // ── 清屏辅助 ──

    private func eraseFromCursor(): Unit {
        // 从光标到屏幕末尾
        let cr = cursor.row; let cc = cursor.col
        for (c in cc..cols) { grid[cr][c] = Cell.empty() }
        for (r in (cr + 1)..rows) {
            for (c in 0..cols) { grid[r][c] = Cell.empty() }
        }
    }

    private func eraseToCursor(): Unit {
        for (r in 0..cursor.row) {
            for (c in 0..cols) { grid[r][c] = Cell.empty() }
        }
        for (c in 0..(cursor.col + 1)) { grid[cursor.row][c] = Cell.empty() }
    }

    private func eraseLine(): Unit {
        for (c in 0..cols) { grid[cursor.row][c] = Cell.empty() }
    }

    private func eraseLineFromCursor(): Unit {
        for (c in cursor.col..cols) { grid[cursor.row][c] = Cell.empty() }
    }

    private func eraseLineToCursor(): Unit {
        for (c in 0..(cursor.col + 1)) { grid[cursor.row][c] = Cell.empty() }
    }

    private func scrollDown(): Unit {
        // 底部行移出，顶部插入空行
        let last = grid[grid.size - 1]
        grid.remove(at:grid.size - 1)

        let newRow = ArrayList<Cell>(cols)
        for (c in 0..cols) { newRow.add(Cell.empty()) }
        grid.add(newRow)
    }
}

// ── 辅助函数 ──

/// 字符显示宽度（CJK 全角字符返回 2，其他返回 1）
/// 与 tui/components/layout.cj 中的 runeWidth 逻辑一致：
/// UTF-8 多字节字符（绝大部分为 CJK / 全角）宽度为 2，单字节为 1
func charWidth(ch: Rune): Int64 {
    let s = String(ch)
    let firstByte = s[0]
    // UTF-8: 0xxxxxxx = 1 byte (ASCII), 110xxxxx = 2 bytes, 1110xxxx = 3 bytes (CJK), 11110xxx = 4 bytes
    if (firstByte >= 0xC0) {
        2
    } else {
        1
    }
}

func parseInt64(s: String): Int64 {
    var result: Int64 = 0
    let bytes = s.toArray()
    for (b in bytes) {
        if (b >= b'0' && b <= b'9') {
            result = result * 10 + Int64(b - b'0')
        }
    }
    result
}
