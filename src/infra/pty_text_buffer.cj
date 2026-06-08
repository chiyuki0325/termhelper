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
    String.fromUtf8(result.toArray())
}
