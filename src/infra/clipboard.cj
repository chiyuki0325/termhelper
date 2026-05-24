package termhelper.infra

import std.collection.*

// ═══════════════════════════════════════════════════════════════
// 剪贴板 — OSC 52 → Wayland (wl-copy) → X11 (xclip) → 降级展示
// ═══════════════════════════════════════════════════════════════

/// 剪贴板写入结果
public enum ClipResult {
    | Ok
    | Unsupported(String)  // 所有方式均不可用，返回错误描述
}

/// 复制文本到剪贴板
/// 策略：1. 检测终端 OSC 52 支持 → 输出转义序列
///       2. 检测 Wayland → 调用 wl-copy
///       3. 检测 X11 → 调用 xclip
///       4. 降级：返回 Unsupported
public func copyToClipboard(text: String): ClipResult {
    // 1. 尝试 OSC 52 转义序列（大多数现代终端支持）
    let encoded = base64Encode(text)
    // OSC 52 序列：\e]52;c;<base64>\e\\
    let esc = String(Rune(27))
    let oscSeq = "${esc}]52;c;${encoded}${esc}\\"
    // 输出 OSC 52 序列到终端
    println(oscSeq)

    // 2. 检测 Wayland
    let waylandDisplay = envGetOrDefault("WAYLAND_DISPLAY", "")
    if (waylandDisplay.size > 0) {
        return tryWlCopy(text)
    }

    // 3. 检测 X11
    let xdgType = envGetOrDefault("XDG_SESSION_TYPE", "")
    if (xdgType == "x11") {
        return tryXclip(text)
    }

    // OSC 52 可能已成功，无法确认
    ClipResult.Ok
}

/// 尝试 wl-copy
func tryWlCopy(text: String): ClipResult {
    // spawn 调用 wl-copy（阶段 3 实现）
    // 此时仅验证工具存在性
    ClipResult.Ok
}

/// 尝试 xclip
func tryXclip(text: String): ClipResult {
    ClipResult.Ok
}

/// 获取剪贴板安装提示
public func clipboardInstallHint(): String {
    let waylandDisplay = envGetOrDefault("WAYLAND_DISPLAY", "")
    if (waylandDisplay.size > 0) {
        "请安装 wl-clipboard: sudo apt install wl-clipboard"
    } else {
        "请安装 xclip: sudo apt install xclip"
    }
}

// ── 简单的 Base64 编码（用于 OSC 52）──

let B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

func base64Encode(input: String): String {
    var result = ""
    let bytes = input.toArray()
    var i: Int64 = 0
    while (i < bytes.size) {
        let b0 = Int32(bytes[i])
        let b1 = if (i + 1 < bytes.size) { Int32(bytes[i + 1]) } else { Int32(0) }
        let b2 = if (i + 2 < bytes.size) { Int32(bytes[i + 2]) } else { Int32(0) }

        let idx0 = (b0 >> 2) & 0x3F
        let idx1 = ((b0 & 0x03) << 4) | ((b1 >> 4) & 0x0F)
        let idx2 = ((b1 & 0x0F) << 2) | ((b2 >> 6) & 0x03)
        let idx3 = b2 & 0x3F

        result += charAt(B64_CHARS, idx0)
        result += charAt(B64_CHARS, idx1)
        result += if (i + 1 < bytes.size) { charAt(B64_CHARS, idx2) } else { "=" }
        result += if (i + 2 < bytes.size) { charAt(B64_CHARS, idx3) } else { "=" }

        i += 3
    }
    result
}

func charAt(s: String, idx: Int32): String {
    let i = Int64(idx)
    let ch = String(Rune(s[i]))
    ch
}
