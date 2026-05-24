package termhelper.infra

import std.collection.*

// ═══════════════════════════════════════════════════════════════
// 剪贴板 — OSC 52 → Wayland (wl-copy) → X11 (xclip) → 降级展示
// 修复 #12: 实现真正的外部工具调用
// ═══════════════════════════════════════════════════════════════

public enum ClipResult {
    | Ok
    | Unsupported(String)
}

/// 复制文本到剪贴板
public func copyToClipboard(text: String): ClipResult {
    // 1. 输出 OSC 52 序列（大多数现代终端支持）
    let esc = String(Rune(27))
    let encoded = base64Encode(text)
    println("${esc}]52;c;${encoded}${esc}\\")

    // 2. 尝试 Wayland wl-copy
    let waylandDisplay = envGetOrDefault("WAYLAND_DISPLAY", "")
    if (waylandDisplay.size > 0) {
        return tryWlCopy(text)
    }

    // 3. 尝试 X11 xclip
    let xdgType = envGetOrDefault("XDG_SESSION_TYPE", "")
    if (xdgType == "x11") {
        return tryXclip(text)
    }

    // OSC 52 可能已成功（无法确认）
    ClipResult.Ok
}

/// 实际调用 wl-copy（管道 stdin，无 shell 注入风险 #8）
func tryWlCopy(text: String): ClipResult {
    let ok = pipeTextToCommand(text, "/usr/bin/wl-copy", ArrayList<String>())
    if (ok) { ClipResult.Ok } else { ClipResult.Unsupported("wl-copy 执行失败") }
}

/// 实际调用 xclip（管道 stdin，无 shell 注入风险 #8）
func tryXclip(text: String): ClipResult {
    let args = ArrayList<String>()
    args.add("-selection"); args.add("clipboard")
    let ok = pipeTextToCommand(text, "/usr/bin/xclip", args)
    if (ok) { ClipResult.Ok } else { ClipResult.Unsupported("xclip 执行失败") }
}

// ── 管道写入工具（修复 #8 命令注入）──

/// 将文本通过管道写入命令的 stdin，无 shell 介入
func pipeTextToCommand(text: String, cmdPath: String, args: ArrayList<String>): Bool {
    unsafe {
        let fds = LibC.malloc<Int32>(count: 2)
        if (pipe(fds) < 0) { LibC.free(fds); return false }
        let readFd = fds.read(0); let writeFd = fds.read(1)

        let pid = fork()
        if (pid < 0) { LibC.free(fds); return false }

        if (pid == 0) {
            close(writeFd)
            dup2(readFd, 0)
            close(readFd)

            // 构造 argv
            let argv = LibC.malloc<CPointer<Int8>>(count: args.size + 2)
            let cmdCStr = LibC.mallocCString(cmdPath)
            argv.write(0, CPointer<Int8>(cmdCStr.getChars()))
            for (i in 0..args.size) {
                let argCStr = LibC.mallocCString(args[i])
                argv.write(i + 1, CPointer<Int8>(argCStr.getChars()))
            }
            argv.write(args.size + 1, CPointer<Int8>())

            execvp(cmdCStr, argv)
            _exit(1)
        }

        // 父进程：写入 stdin
        close(readFd)
        let bytes = text.toArray()
        let writeBuf = LibC.malloc<UInt8>(count: bytes.size)
        for (i in 0..bytes.size) { writeBuf.write(i, bytes[i]) }
        write(writeFd, writeBuf, UInt64(bytes.size))
        LibC.free(writeBuf)
        close(writeFd)

        // 等待子进程
        let statusPtr = LibC.malloc<Int32>(count: 1)
        statusPtr.write(0, 0)
        waitpid(pid, statusPtr, 0)
        let rawStatus = statusPtr.read(0)
        LibC.free(statusPtr); LibC.free(fds)

        (rawStatus & 0x7F) == 0 && ((rawStatus >> 8) & 0xFF) == 0
    }
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

// ── Shell 转义辅助 ──

func escapeForShell(s: String): String {
    // 简单的单引号转义：将 ' 替换为 '\''
    var result = ""
    let bytes = s.toArray()
    for (b in bytes) {
        if (b == b'\'') {
            result += "'\\''"
        } else {
            result += String(Rune(Int32(b)))
        }
    }
    result
}

// ── Base64 编码 ──

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

func charAt(s: String, idx: Int32): String { String(Rune(s[Int64(idx)])) }
