package termhelper.infra

import termhelper.i18n.*
import std.fs.*

// ═══════════════════════════════════════════════════════════════
// Shell RC 管理 — 安装/卸载 alias/def 命令定义
// ═══════════════════════════════════════════════════════════════

let MARKER_START = "# >>> termhelper >>>"
let MARKER_END = "# <<< termhelper <<<"

public struct ShellInfo {
    public let name: String
    public let rcPath: String

    public init(name: String, rcPath: String) {
        this.name = name
        this.rcPath = rcPath
    }
}

public func detectShell(): ShellInfo {
    let shell = envGetShell()
    let home = envGetHome()

    if (strContains(shell, "fish")) {
        ShellInfo("fish", "${home}/.config/fish/config.fish")
    } else if (strContains(shell, "nu")) {
        ShellInfo("nushell", "${home}/.config/nushell/config.nu")
    } else if (strContains(shell, "zsh")) {
        ShellInfo("zsh", "${home}/.zshrc")
    } else {
        ShellInfo("bash", "${home}/.bashrc")
    }
}

public func generateAlias(shell: String): String {
    if (shell == "fish") {
        "alias '??' termhelper"
    } else if (shell == "nushell") {
        "def \"??\" [ ...args ] { termhelper ...$args }"
    } else {
        "alias '??'='termhelper'"
    }
}

public func install(rcPath: String, shell: String): Bool {
    let path = Path(rcPath)
    var content = ""
    if (exists(path)) {
        content = shellReadFile(rcPath)
    }

    if (strContains(content, MARKER_START)) {
        if (!strContains(content, MARKER_END)) {
            println("${uiText("shell_marker_corrupt")} ${rcPath}")
            return false
        }
        println(uiText("shell_already_installed"))
        return false
    }

    let aliasLine = generateAlias(shell)
    let block = "\n${MARKER_START}\n${aliasLine}\n${MARKER_END}\n"
    shellWriteFile(rcPath, content + block)
    println("${uiText("shell_installed_to")} ${rcPath}")
    println("${uiText("shell_source_hint")} ${rcPath}  ${uiText("shell_or_restart")}")
    true
}

public func uninstall(rcPath: String): Bool {
    let path = Path(rcPath)
    if (!exists(path)) {
        println("${uiText("shell_rc_missing")}: ${rcPath}")
        return false
    }

    let content = shellReadFile(rcPath)
    let startIdx = strFind(content, MARKER_START)
    if (startIdx < 0) {
        println(uiText("shell_marker_missing"))
        return false
    }
    let endIdx = strFind(content, MARKER_END)
    if (endIdx < 0 || endIdx <= startIdx) {
        println("${uiText("shell_marker_corrupt")} ${rcPath}")
        return false
    }

    let before = content[0..startIdx]
    let afterEnd = endIdx + MARKER_END.size
    var afterStart = afterEnd
    if (afterStart < content.size && content[afterStart] == b'\n') {
        afterStart += 1
    }
    let after = content[afterStart..]
    shellWriteFile(rcPath, before + after)
    println("${uiText("shell_uninstalled_from")} ${rcPath}")
    true
}

// ── 文件操作 ──

func shellReadFile(path: String): String {
    let data = File.readFrom(Path(path))
    String.fromUtf8(data)
}

func shellWriteFile(path: String, content: String): Unit {
    ensureShellParentDir(path)
    try (f = File(Path(path), Write)) {
        f.write(content.toArray())
    }
}

func ensureShellParentDir(filePath: String): Unit {
    var lastSep: Int64 = -1
    for (i in 0..filePath.size) {
        if (filePath[i] == b'/') {
            lastSep = i
        }
    }
    if (lastSep > 0) {
        let dirPath = filePath[0..lastSep]
        let p = Path(dirPath)
        if (!exists(p)) {
            Directory.create(p, recursive: true)
        }
    }
}
