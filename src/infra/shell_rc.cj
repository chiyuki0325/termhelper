package termhelper.infra

import std.fs.*

// ═══════════════════════════════════════════════════════════════
// Shell RC 管理 — 安装/卸载 alias/def 命令定义
// ═══════════════════════════════════════════════════════════════

let MARKER_START = "# >>> termhelper >>>"
let MARKER_END   = "# <<< termhelper <<<"

public struct ShellInfo {
    public let name: String
    public let rcPath: String

    public init(name: String, rcPath: String) {
        this.name = name; this.rcPath = rcPath
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
        println("termhelper 似乎已经安装过了")
        return false
    }

    let aliasLine = generateAlias(shell)
    let block = "\n${MARKER_START}\n${aliasLine}\n${MARKER_END}\n"
    shellWriteFile(rcPath, content + block)
    println("已安装 Shell 集成到 ${rcPath}")
    println("请运行: source ${rcPath}  或重启终端")
    true
}

public func uninstall(rcPath: String): Bool {
    let path = Path(rcPath)
    if (!exists(path)) {
        println("RC 文件不存在: ${rcPath}")
        return false
    }

    let content = shellReadFile(rcPath)
    let startIdx = strFind(content, MARKER_START)
    if (startIdx < 0) {
        println("未找到 termhelper 标记区块")
        return false
    }
    let endIdx = strFind(content, MARKER_END)
    if (endIdx < 0 || endIdx <= startIdx) {
        println("标记区块损坏，请手动检查 ${rcPath}")
        return false
    }

    let before = content[0..startIdx]
    let afterEnd = endIdx + MARKER_END.size
    let after = content[afterEnd..]
    shellWriteFile(rcPath, before + after)
    println("已从 ${rcPath} 移除 termhelper Shell 集成")
    true
}

// ── 文件操作 ──

func shellReadFile(path: String): String {
    let data = File.readFrom(Path(path))
    String.fromUtf8(data)
}

func shellWriteFile(path: String, content: String): Unit {
    try (f = File(Path(path), Write)) {
        f.write(content.toArray())
    }
}
