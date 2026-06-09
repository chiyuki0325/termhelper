package termhelper.infra

import std.collection.*

// ═══════════════════════════════════════════════════════════════
// PtyTextBuffer — 轻量 PTY 输出缓冲区（仅 LLM 用）
//
// 替代 TerminalBuffer 的纯文本部分。只累积原始字节，
// 提供 ANSI 剥离后的纯文本供 LLM 分析。
// 显示端的 ANSI→样式转换由 Rust FFI (ratatui_ansi_text) 完成。
// ═══════════════════════════════════════════════════════════════

public class PtyTextBuffer {
    private var raw: ArrayList<UInt8>

    public init() {
        this.raw = ArrayList<UInt8>()
    }

    /// 追加 PTY 输出数据
    public func append(data: String): Unit {
        let bytes = data.toArray()
        for (b in bytes) { raw.add(b) }
    }

    /// 追加原始字节
    public func appendBytes(bytes: Array<UInt8>): Unit {
        for (b in bytes) { raw.add(b) }
    }

    /// 获取完整原始字节（供 Rust FFI 使用）
    public func rawBytes(): Array<UInt8> {
        raw.toArray()
    }

    /// 获取原始字节大小
    public func size(): Int64 {
        raw.size
    }

    /// 获取剥离 ANSI 转义序列后的纯文本（供 LLM 分析使用）
    public func toPlainText(): String {
        stripAnsiEscapes(raw.toArray())
    }

    /// 清空缓冲区
    public func clear(): Unit {
        raw.clear()
    }
}

public class PtyLlmContextSnapshot {
    public let checkpoint: String
    public let recent: String
    public let delta: String
    public let contextBytes: Int64
    public let deltaBytes: Int64
    public let compactCount: Int64

    public init(checkpoint: String, recent: String, delta: String, contextBytes: Int64, deltaBytes: Int64,
        compactCount: Int64) {
        this.checkpoint = checkpoint
        this.recent = recent
        this.delta = delta
        this.contextBytes = contextBytes
        this.deltaBytes = deltaBytes
        this.compactCount = compactCount
    }
}

public class PtyLlmContextBuffer {
    private var normalized: ArrayList<UInt8>
    private var compactedPrefix: String
    private var baseOffset: Int64
    private var lastSentOffset: Int64
    private let compactThresholdBytes: Int64
    private let compactKeepBytes: Int64
    private let contextMaxBytes: Int64
    private var compactCount: Int64
    private let normalizer: TerminalTextNormalizer

    public init(compactThresholdBytes: Int64, compactKeepBytes: Int64, contextMaxBytes: Int64) {
        this.normalized = ArrayList<UInt8>()
        this.compactedPrefix = ""
        this.baseOffset = 0
        this.lastSentOffset = 0
        this.compactThresholdBytes = compactThresholdBytes
        this.compactKeepBytes = compactKeepBytes
        this.contextMaxBytes = contextMaxBytes
        this.compactCount = 0
        this.normalizer = TerminalTextNormalizer()
    }

    public func append(data: String): Bool {
        let text = normalizer.feed(data)
        if (text.size > 0) {
            for (b in text.toArray()) { normalized.add(b) }
            if (normalized.size > compactThresholdBytes) { compact() }
        }
        text.size > 0 || normalizer.preview().size > 0
    }

    public func finishOpenLine(): Bool {
        let text = normalizer.flush()
        if (text.size == 0) { return false }
        for (b in text.toArray()) { normalized.add(b) }
        if (normalized.size > compactThresholdBytes) { compact() }
        true
    }

    public func currentOffset(): Int64 {
        baseOffset + normalized.size
    }

    public func sentOffset(): Int64 {
        lastSentOffset
    }

    public func markSent(): Unit {
        lastSentOffset = currentOffset()
    }

    public func markSentTo(offset: Int64): Unit {
        let current = currentOffset()
        if (offset < baseOffset) {
            lastSentOffset = baseOffset
        } else if (offset > current) {
            lastSentOffset = current
        } else {
            lastSentOffset = offset
        }
    }

    public func rawSize(): Int64 {
        normalized.size
    }

    public func getCompactCount(): Int64 {
        compactCount
    }

    public func hasPreview(): Bool {
        normalizer.preview().size > 0
    }

    public func snapshot(): PtyLlmContextSnapshot {
        let preview = normalizer.preview()
        let recentBase = tailString(normalized, contextMaxBytes)
        let recent = appendPreview(recentBase, preview)
        let delta = appendPreview(deltaString(), preview)
        let checkpoint = if (compactedPrefix.size > 0) { compactedPrefix } else { "No compacted history." }
        PtyLlmContextSnapshot(
            checkpoint,
            recent,
            delta,
            checkpoint.size + recent.size + delta.size,
            delta.size,
            compactCount)
    }

    private func deltaString(): String {
        if (lastSentOffset < baseOffset) {
            let text = tailString(normalized, contextMaxBytes)
            if (text.size == 0) { return "[Output before this point was compacted.]" }
            return "[Output before this point was compacted.]\n${text}"
        }
        let start = lastSentOffset - baseOffset
        if (start >= normalized.size) { return "" }
        bytesRangeToString(normalized, start, normalized.size)
    }

    private func compact(): Unit {
        let keep = if (compactKeepBytes < normalized.size) { compactKeepBytes } else { normalized.size }
        let removeLen = normalized.size - keep
        let removed = bytesRangeToString(normalized, 0, removeLen)
        let tail = bytesRange(normalized, removeLen, normalized.size)
        let summary = buildCompactSummary(removed, removeLen)
        if (compactedPrefix.size == 0) {
            compactedPrefix = summary
        } else {
            compactedPrefix = compactedPrefix + "\n" + summary
        }
        baseOffset += removeLen
        if (lastSentOffset < baseOffset) { lastSentOffset = baseOffset }
        normalized = tail
        compactCount += 1
    }

    private func buildCompactSummary(removed: String, removedBytes: Int64): String {
        let important = extractImportantLines(removed, 12)
        var result = "[Earlier terminal output compacted: ${removedBytes} bytes removed."
        if (important.size > 0) {
            result += "\nImportant retained lines:\n${important}"
        }
        result + "]"
    }
}

public class TerminalTextNormalizer {
    private var line: ArrayList<UInt8>
    private var cursorCol: Int64
    private var output: ArrayList<UInt8>
    private var progressUpdateCount: Int64
    private var lineWasOverwritten: Bool
    private var pendingEsc: ArrayList<UInt8>
    private var inEsc: Bool

    public init() {
        this.line = ArrayList<UInt8>()
        this.cursorCol = 0
        this.output = ArrayList<UInt8>()
        this.progressUpdateCount = 0
        this.lineWasOverwritten = false
        this.pendingEsc = ArrayList<UInt8>()
        this.inEsc = false
    }

    public func feed(data: String): String {
        output.clear()
        let bytes = data.toArray()
        for (b in bytes) { processByte(b) }
        safeUtf8(output.toArray())
    }

    public func flush(): String {
        output.clear()
        if (line.size > 0 || progressUpdateCount > 0) {
            commitLine()
        }
        safeUtf8(output.toArray())
    }

    public func preview(): String {
        let text = trimRightAscii(safeUtf8(line.toArray()))
        if (text.size == 0) { return "" }
        if (lineWasOverwritten || progressUpdateCount > 1) {
            "[current progress latest: ${text}]"
        } else {
            "[current line: ${text}]"
        }
    }

    private func processByte(b: UInt8): Unit {
        if (inEsc) {
            pendingEsc.add(b)
            if (pendingEsc.size > 2 && isAnsiFinalByte(b)) {
                handleEscape()
                inEsc = false
                pendingEsc.clear()
            }
            return
        }

        if (b == 27) {
            inEsc = true
            pendingEsc.clear()
            pendingEsc.add(b)
        } else if (b == b'\r') {
            cursorCol = 0
            progressUpdateCount += 1
            lineWasOverwritten = true
        } else if (b == b'\n') {
            commitLine()
        } else if (b == b'\b') {
            if (cursorCol > 0) { cursorCol -= 1 }
            progressUpdateCount += 1
            lineWasOverwritten = true
        } else if (b == b'\t') {
            writeUtf8Byte(b' ')
            writeUtf8Byte(b' ')
            writeUtf8Byte(b' ')
            writeUtf8Byte(b' ')
        } else if (b >= 32) {
            writeUtf8Byte(b)
        }
    }

    private func writeUtf8Byte(b: UInt8): Unit {
        let advanceCursor = !isUtf8Continuation(b)
        while (line.size < cursorCol) { line.add(b' ') }
        if (advanceCursor && cursorCol < line.size && utf8SequenceLength(line[cursorCol]) > 0) {
            removeUtf8SequenceAtCursor()
        }
        if (advanceCursor) {
            if (cursorCol < line.size) {
                line[cursorCol] = b
            } else {
                line.add(b)
            }
            cursorCol += 1
        } else {
            line.add(b)
        }
    }

    private func removeUtf8SequenceAtCursor(): Unit {
        while (cursorCol + 1 < line.size && isUtf8Continuation(line[cursorCol + 1])) {
            line.remove(at: cursorCol + 1)
        }
    }

    private func commitLine(): Unit {
        let text = trimRightAscii(safeUtf8(line.toArray()))
        if (text.size > 0) {
            if (lineWasOverwritten || progressUpdateCount > 1) {
                appendOutput("[progress updated ${progressUpdateCount} times, latest: ${text}]\n")
            } else {
                appendOutput(text + "\n")
            }
        }
        line.clear()
        cursorCol = 0
        progressUpdateCount = 0
        lineWasOverwritten = false
    }

    private func handleEscape(): Unit {
        if (pendingEsc.size < 2) { return }
        if (pendingEsc[1] != b'[') { return }
        let finalByte = pendingEsc[pendingEsc.size - 1]
        let param = firstAnsiParam(pendingEsc)
        if (finalByte == b'K') {
            handleEraseInLine(param)
        } else if (finalByte == b'G') {
            cursorCol = if (param <= 1) { 0 } else { param - 1 }
            progressUpdateCount += 1
            lineWasOverwritten = true
        } else if (finalByte == b'D') {
            let n = if (param <= 0) { 1 } else { param }
            cursorCol = if (cursorCol > n) { cursorCol - n } else { 0 }
            progressUpdateCount += 1
            lineWasOverwritten = true
        } else if (finalByte == b'C') {
            let n = if (param <= 0) { 1 } else { param }
            cursorCol += n
            progressUpdateCount += 1
            lineWasOverwritten = true
        } else if (finalByte == b'm') {
            ()
        }
    }

    private func handleEraseInLine(param: Int64): Unit {
        if (param == 2) {
            line.clear()
            cursorCol = 0
        } else if (param == 1) {
            var i: Int64 = 0
            while (i <= cursorCol && i < line.size) {
                line[i] = b' '
                i += 1
            }
        } else {
            var i = cursorCol
            while (i < line.size) {
                line[i] = b' '
                i += 1
            }
        }
        progressUpdateCount += 1
        lineWasOverwritten = true
    }

    private func appendOutput(text: String): Unit {
        for (b in text.toArray()) { output.add(b) }
    }
}

/// 剥离 ANSI 转义序列（ESC[...m, ESC[...A-J, 等）
func stripAnsiEscapes(bytes: Array<UInt8>): String {
    var result = ArrayList<UInt8>()
    var i: Int64 = 0
    while (i < bytes.size) {
        if (bytes[i] == 27 && i + 1 < bytes.size && bytes[i + 1] == b'[') {
            // ESC[ ... 序列，跳到字母结尾
            i += 2
            while (i < bytes.size && !((bytes[i] >= b'A' && bytes[i] <= b'Z') || (bytes[i] >= b'a' && bytes[i] <= b'z'))) {
                i += 1
            }
            if (i < bytes.size) { i += 1 }  // 跳过结尾字母
        } else if (bytes[i] == 27 && i + 1 < bytes.size && bytes[i + 1] == b']') {
            // OSC 序列 (ESC])，以 BEL (\x07) 或 ST 结尾
            i += 2
            while (i < bytes.size && bytes[i] != 7 && bytes[i] != 27) {
                i += 1
            }
            if (i < bytes.size && bytes[i] == 27) { i += 1 } // ST (ESC\)
            if (i < bytes.size) { i += 1 } // BEL
        } else {
            result.add(bytes[i])
            i += 1
        }
    }
    safeUtf8(result.toArray())
}

func isAnsiFinalByte(b: UInt8): Bool {
    b >= 64 && b <= 126
}

func firstAnsiParam(bytes: ArrayList<UInt8>): Int64 {
    var result: Int64 = 0
    var hasDigit = false
    var i: Int64 = 2
    while (i < bytes.size - 1) {
        let b = bytes[i]
        if (b >= b'0' && b <= b'9') {
            result = result * 10 + Int64(b - b'0')
            hasDigit = true
        } else if (b == b';') {
            break
        }
        i += 1
    }
    if (hasDigit) { result } else { 0 }
}

func bytesRange(bytes: ArrayList<UInt8>, start: Int64, end: Int64): ArrayList<UInt8> {
    let result = ArrayList<UInt8>()
    var i = if (start < 0) { 0 } else { start }
    let stop = if (end > bytes.size) { bytes.size } else { end }
    while (i < stop) {
        result.add(bytes[i])
        i += 1
    }
    result
}

func bytesRangeToString(bytes: ArrayList<UInt8>, start: Int64, end: Int64): String {
    safeUtf8(bytesRange(bytes, start, end).toArray())
}

func tailString(bytes: ArrayList<UInt8>, maxBytes: Int64): String {
    let start = if (bytes.size > maxBytes) { bytes.size - maxBytes } else { 0 }
    bytesRangeToString(bytes, start, bytes.size)
}

func appendPreview(text: String, preview: String): String {
    if (preview.size == 0) { return text }
    if (text.size == 0) { return preview }
    text + "\n" + preview
}

func safeUtf8(bytes: Array<UInt8>): String {
    let result = ArrayList<UInt8>()
    var i: Int64 = 0
    while (i < bytes.size) {
        let b = bytes[i]
        if (b < 0x80) {
            result.add(b)
            i += 1
        } else {
            let len = utf8SequenceLength(b)
            if (len == 0 || i + len > bytes.size) {
                appendReplacementRune(result)
                i += 1
            } else {
                var valid = true
                for (j in 1..len) {
                    if (!isUtf8Continuation(bytes[i + j])) {
                        valid = false
                        break
                    }
                }
                if (valid) {
                    for (j in 0..len) { result.add(bytes[i + j]) }
                    i += len
                } else {
                    appendReplacementRune(result)
                    i += 1
                }
            }
        }
    }
    String.fromUtf8(result.toArray())
}

func utf8SequenceLength(b: UInt8): Int64 {
    if (b >= 0xC2 && b <= 0xDF) {
        2
    } else if (b >= 0xE0 && b <= 0xEF) {
        3
    } else if (b >= 0xF0 && b <= 0xF4) {
        4
    } else {
        0
    }
}

func isUtf8Continuation(b: UInt8): Bool {
    b >= 0x80 && b <= 0xBF
}

func appendReplacementRune(result: ArrayList<UInt8>): Unit {
    result.add(0xEF)
    result.add(0xBF)
    result.add(0xBD)
}

func trimRightAscii(text: String): String {
    if (text.size == 0) { return text }
    var end = text.size
    while (end > 0 && (text[end - 1] == b' ' || text[end - 1] == b'\t' || text[end - 1] == b'\r')) {
        end -= 1
    }
    text[0..end]
}

func extractImportantLines(text: String, limit: Int64): String {
    let lines = text.split("\n")
    let selected = ArrayList<String>()
    for (line in lines) {
        let trimmed = line.trimAscii()
        if (trimmed.size == 0) { continue }
        if (isImportantPtyLine(trimmed)) {
            selected.add(trimmed)
            while (selected.size > limit) { selected.remove(at: 0) }
        }
    }
    if (selected.size == 0) {
        var i = lines.size - 1
        while (i >= 0 && selected.size < limit) {
            let trimmed = lines[i].trimAscii()
            if (trimmed.size > 0) { selected.add(trimmed) }
            i -= 1
        }
    }
    joinLines(selected)
}

func isImportantPtyLine(line: String): Bool {
    let lower = line.toAsciiLower()
    lower.contains("error") || lower.contains("failed") || lower.contains("denied") ||
        lower.contains("permission") || lower.contains("not found") || lower.contains("password") ||
        lower.contains("[y/n]") || lower.contains("[y/n]") || lower.endsWith("?") || lower.endsWith(":") ||
        lower.contains("progress updated")
}

func joinLines(lines: ArrayList<String>): String {
    var result = ""
    for (i in 0..lines.size) {
        if (i > 0) { result += "\n" }
        result += lines[i]
    }
    result
}
