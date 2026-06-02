package termhelper.i18n

import std.env.*

public enum Language {
    | Zh
    | En
}

public func currentLanguage(): Language {
    localeToLanguage(activeLocale())
}

public func activeLocale(): String {
    let lcAll = envValue("LC_ALL").trimAscii()
    if (lcAll.size > 0) {
        return lcAll
    }

    let lang = envValue("LANG").trimAscii()
    if (lang.size > 0) {
        return lang
    }

    "C"
}

public func isChinese(): Bool {
    match (currentLanguage()) {
        case Language.Zh => true
        case Language.En => false
    }
}

public func uiText(key: String): String {
    if (isChinese()) {
        zhText(key)
    } else {
        enText(key)
    }
}

public func uiCountChecks(count: Int64): String {
    if (isChinese()) {
        "${count} 项检查"
    } else {
        "${count} checks"
    }
}

public func uiUnknownArgument(arg: String): String {
    if (isChinese()) {
        "未知参数: ${arg}"
    } else {
        "Unknown argument: ${arg}"
    }
}

public func uiConfigLoadFailed(message: String): String {
    if (isChinese()) {
        "配置加载失败: ${message}"
    } else {
        "Failed to load config: ${message}"
    }
}

public func uiTuiStartFailed(message: String): String {
    if (isChinese()) {
        "TUI 启动失败: ${message}"
    } else {
        "Failed to start TUI: ${message}"
    }
}

public func uiTuiDemoStartFailed(message: String): String {
    if (isChinese()) {
        "TUI 样式预览启动失败: ${message}"
    } else {
        "Failed to start TUI style demo: ${message}"
    }
}

public func uiConfigJsonParseFailed(path: String, message: String): String {
    if (isChinese()) {
        "配置文件 JSON 解析失败: ${path}: ${message}"
    } else {
        "Failed to parse config JSON: ${path}: ${message}"
    }
}

public func uiConfigMustBeObject(path: String): String {
    if (isChinese()) {
        "配置文件必须是 JSON Object: ${path}"
    } else {
        "Config file must be a JSON object: ${path}"
    }
}

public func uiLlmParseFailed(finishReason: String, contentSize: Int64): String {
    if (isChinese()) {
        "LLM 返回无法解析为 termhelper 结构化响应。finishReason: ${finishReason}, content_size=${contentSize}。完整内容已写入 debug trace。"
    } else {
        "LLM response could not be parsed as a termhelper structured response. finishReason: ${finishReason}, content_size=${contentSize}. Full content was written to debug trace."
    }
}

public func uiRetryStatus(attempt: Int64, reason: String): String {
    if (isChinese()) {
        "第 ${attempt} 次重试: ${reason}"
    } else {
        "attempt ${attempt}: ${reason}"
    }
}

public func uiModifyPrompt(command: String): String {
    if (isChinese()) {
        "写出命令修改建议。\n\n当前命令:\n${command}"
    } else {
        "Describe how to modify the command.\n\nCurrent command:\n${command}"
    }
}

public func uiClipboardError(reason: String, hint: String, command: String): String {
    if (isChinese()) {
        "${reason}\n\n${hint}\n\n命令:\n${command}"
    } else {
        "${reason}\n\n${hint}\n\nCommand:\n${command}"
    }
}

public func llmOutputLanguageName(): String {
    if (isChinese()) {
        "Chinese"
    } else {
        "English"
    }
}

public func llmLanguageInstruction(): String {
    let name = llmOutputLanguageName()
    """

Output language:
- Write every natural-language value in ${name}.
- This includes explanation.summary, explanation.breakdown[].explanation, safety.warnings[], investigate reason/rationale, clarify question, and PTY agent questions/reasons/summaries.
- Keep JSON keys, enum values, shell commands, command components, tool action names, and shell syntax exactly as specified.
"""
}

public func llmObjectModeExamples(): String {
    if (isChinese()) {
        """
Q: 删除所有tmp开头的文件夹
A: {"type":"command","data":{"command":"rm -rf /tmp/tmp*","explanation":{"summary":"递归删除 /tmp 中名称以 tmp 开头的目录和文件","breakdown":[{"component":"rm","explanation":"删除文件或目录的命令"},{"component":"-rf","explanation":"递归并强制删除目录及其内容，不进行交互确认"},{"component":"/tmp/tmp*","explanation":"匹配 /tmp 中所有以 tmp 开头的项目"}]},"interactive":false,"safety":{"level":"danger","warnings":["带通配符的递归删除操作具有破坏性","删除后无法撤销","执行前请确认通配符只匹配目标路径"]}}}

Q: 当前目录有哪些文件
A: {"type":"command","data":{"command":"ls -la","explanation":{"summary":"列出当前目录中的文件和目录，包括隐藏项目和详细信息","breakdown":[{"component":"ls","explanation":"列出目录内容的常用命令"},{"component":"-la","explanation":"显示隐藏项目并使用长格式输出"}]},"interactive":false,"safety":{"level":"safe","warnings":[]}}}

Q: 系统用的什么包管理器
A: {"type":"investigate","data":{"reason":"需要先识别 Linux 发行版和可用包管理器，不能猜测发行版相关命令","commands":[{"command":"cat /etc/os-release","rationale":"识别当前 Linux 发行版"},{"command":"for p in rpm-ostree swupd xbps-install eopkg guix nix home-manager emerge apk zypper dnf yum pacman oma flatpak snap apt apt-get; do command -v \"$p\"; done","rationale":"按从冷门到热门的顺序检查系统中实际存在的包管理器"}]}}

Q: 没有环境事实时安装 htop
A: {"type":"investigate","data":{"reason":"安装软件需要使用发行版相关的包管理器，但当前没有可用的包管理器事实，必须先调查实际可用的工具","commands":[{"command":"cat /etc/os-release","rationale":"识别当前 Linux 发行版"},{"command":"for p in rpm-ostree swupd xbps-install eopkg guix nix home-manager emerge apk zypper dnf yum pacman oma flatpak snap apt apt-get; do command -v \"$p\"; done","rationale":"按从冷门到热门的顺序检查系统中实际存在的包管理器"}]}}

Q: 已知环境事实:
- id=distro.current: 当前系统发行版 ID 是 aosc。
- id=packageManager.oma: 系统中存在包管理器 oma，路径是 /usr/bin/oma。
- id=packageManager.apt: 系统中存在包管理器 apt，路径是 /usr/bin/apt。
更新系统
A: {"type":"command","data":{"command":"sudo oma upgrade","explanation":{"summary":"使用已知存在的 oma 包管理器更新系统","breakdown":[{"component":"sudo","explanation":"以管理员权限运行系统更新命令"},{"component":"oma","explanation":"环境事实中已确认存在的包管理器"},{"component":"upgrade","explanation":"升级系统中可更新的软件包"}]},"interactive":true,"safety":{"level":"privilege","warnings":["系统更新需要管理员权限","更新过程中可能安装、升级或移除软件包，请确认操作摘要"]}}}

Q: 环境调查结果:
$ cat /etc/os-release
exit=0
stdout:
ID=arch
NAME="Arch Linux"
$ for p in rpm-ostree swupd xbps-install eopkg guix nix home-manager emerge apk zypper dnf yum pacman oma flatpak snap apt apt-get; do command -v "$p"; done
exit=0
stdout:
/usr/bin/pacman
A: {"type":"command","data":{"command":"sudo pacman -S htop","explanation":{"summary":"使用 pacman 安装 htop","breakdown":[{"component":"sudo","explanation":"以管理员权限运行安装命令"},{"component":"pacman","explanation":"Arch Linux 的包管理器"},{"component":"-S","explanation":"同步并安装指定软件包"},{"component":"htop","explanation":"要安装的软件包名称"}]},"interactive":true,"safety":{"level":"privilege","warnings":["安装软件需要管理员权限","执行前请确认软件包名称正确"]},"factEdits":[{"op":"add","id":"distro.current","oldText":"","newText":"当前系统发行版是 Arch Linux，/etc/os-release 中 ID=arch。","source":"cat /etc/os-release","reason":"诊断输出明确包含 ID=arch 和 Arch Linux 名称"},{"op":"add","id":"packageManager.pacman","oldText":"","newText":"当前系统存在包管理器 pacman，路径是 /usr/bin/pacman。","source":"for p in rpm-ostree swupd xbps-install eopkg guix nix home-manager emerge apk zypper dnf yum pacman oma flatpak snap apt apt-get; do command -v \"$p\"; done","reason":"诊断输出显示 pacman 路径"}]}}

Q: 帮我安装一个东西
A: {"type":"clarify","data":{"question":"你想安装什么软件？"}}
"""
    } else {
        """
Q: Delete all folders starting with tmp
A: {"type":"command","data":{"command":"rm -rf /tmp/tmp*","explanation":{"summary":"Recursively delete all directories and files in /tmp whose names start with tmp","breakdown":[{"component":"rm","explanation":"File removal command"},{"component":"-rf","explanation":"Recursive and force flags: delete directories and contents without prompting"},{"component":"/tmp/tmp*","explanation":"Glob pattern matching all items in /tmp starting with tmp"}]},"interactive":false,"safety":{"level":"danger","warnings":["Destructive recursive removal with wildcard","No undo possible","Verify the glob pattern matches intended targets before running"]}}}

Q: What files are in this directory?
A: {"type":"command","data":{"command":"ls -la","explanation":{"summary":"List files and directories in the current directory, including hidden entries and details","breakdown":[{"component":"ls","explanation":"Common command for listing directory contents"},{"component":"-la","explanation":"Show hidden entries and use long output format"}]},"interactive":false,"safety":{"level":"safe","warnings":[]}}}

Q: Which package manager does this system use?
A: {"type":"investigate","data":{"reason":"Need to identify the Linux distribution and available package manager instead of guessing distro-specific commands","commands":[{"command":"cat /etc/os-release","rationale":"Identify the Linux distribution"},{"command":"for p in rpm-ostree swupd xbps-install eopkg guix nix home-manager emerge apk zypper dnf yum pacman oma flatpak snap apt apt-get; do command -v \"$p\"; done","rationale":"Check package managers from less common to more common, with apt-get last"}]}}

Q: Install htop when no environment facts are known
A: {"type":"investigate","data":{"reason":"Installing software requires a distribution-specific package manager, but no package manager fact is available, so the current system tools must be investigated first","commands":[{"command":"cat /etc/os-release","rationale":"Identify the Linux distribution"},{"command":"for p in rpm-ostree swupd xbps-install eopkg guix nix home-manager emerge apk zypper dnf yum pacman oma flatpak snap apt apt-get; do command -v \"$p\"; done","rationale":"Check package managers from less common to more common, with apt-get last"}]}}

Q: Known environment facts:
- id=distro.current: The current distribution ID is aosc.
- id=packageManager.oma: The system has package manager oma at /usr/bin/oma.
- id=packageManager.apt: The system has package manager apt at /usr/bin/apt.
Update the system
A: {"type":"command","data":{"command":"sudo oma upgrade","explanation":{"summary":"Update the system with the known available oma package manager","breakdown":[{"component":"sudo","explanation":"Run the system update command with administrator privileges"},{"component":"oma","explanation":"Package manager confirmed by environment facts"},{"component":"upgrade","explanation":"Upgrade installed packages that have available updates"}]},"interactive":true,"safety":{"level":"privilege","warnings":["System updates require administrator privileges","The update may install, upgrade, or remove packages; review the transaction summary"]}}}

Q: Environment investigation results:
$ cat /etc/os-release
exit=0
stdout:
ID=arch
NAME="Arch Linux"
$ for p in rpm-ostree swupd xbps-install eopkg guix nix home-manager emerge apk zypper dnf yum pacman oma flatpak snap apt apt-get; do command -v "$p"; done
exit=0
stdout:
/usr/bin/pacman
A: {"type":"command","data":{"command":"sudo pacman -S htop","explanation":{"summary":"Install htop with pacman","breakdown":[{"component":"sudo","explanation":"Run the install command with administrator privileges"},{"component":"pacman","explanation":"Package manager used by Arch Linux"},{"component":"-S","explanation":"Synchronize and install the requested package"},{"component":"htop","explanation":"Package name to install"}]},"interactive":true,"safety":{"level":"privilege","warnings":["Installing software requires administrator privileges","Confirm the package name before running"]},"factEdits":[{"op":"add","id":"distro.current","oldText":"","newText":"The current distribution is Arch Linux; /etc/os-release contains ID=arch.","source":"cat /etc/os-release","reason":"The diagnostic output explicitly contains ID=arch and the Arch Linux name"},{"op":"add","id":"packageManager.pacman","oldText":"","newText":"The current system has package manager pacman at /usr/bin/pacman.","source":"for p in rpm-ostree swupd xbps-install eopkg guix nix home-manager emerge apk zypper dnf yum pacman oma flatpak snap apt apt-get; do command -v \"$p\"; done","reason":"The diagnostic output shows the pacman path"}]}}

Q: Help me install something
A: {"type":"clarify","data":{"question":"What software would you like to install?"}}
"""
    }
}

func localeToLanguage(locale: String): Language {
    let normalized = lowerAscii(locale)
    if (normalized.startsWith("zh")) {
        Language.Zh
    } else {
        Language.En
    }
}

func envValue(key: String): String {
    match (getVariable(key)) {
        case Some(v) => v
        case None => ""
    }
}

func lowerAscii(value: String): String {
    var out = ""
    for (b in value) {
        if (b >= UInt8(65) && b <= UInt8(90)) {
            out += String(Rune(Int32(b) + 32))
        } else {
            out += String(Rune(Int32(b)))
        }
    }
    out
}

func zhText(key: String): String {
    match (key) {
        case "usage_short" => "用法: termhelper <查询> | --install | --uninstall | --help"
        case "try_help" => "尝试: termhelper --help"
        case "install_placeholder" => "[阶段 1 占位] 安装 Shell 集成"
        case "uninstall_placeholder" => "[阶段 1 占位] 卸载 Shell 集成"
        case "usage_debug" => "用法: termhelper --debug <查询>"
        case "missing_api_key" => "缺少 LLM API Key。请设置 LLM_API_KEY / OPENAI_API_KEY，或写入 ~/.config/termhelper/config.json。"
        case "help_title" => "termhelper — Linux 终端智能助手"
        case "help_desc" => "将自然语言转换为可执行的 Shell 命令，辅以说明和安全警告"
        case "help_usage" => "用法:"
        case "help_query" => "  termhelper <自然语言查询>    执行查询，启动全屏 TUI"
        case "help_install" => "  termhelper --install          安装 Shell 集成 (alias/def 写入 RC 文件)"
        case "help_uninstall" => "  termhelper --uninstall        卸载 Shell 集成 (从 RC 文件移除)"
        case "help_debug" => "  termhelper --debug <查询>     CLI 调试模式，打印 LLMResponse JSON"
        case "help_demo" => "  termhelper --tui-demo         展示彩色 TUI 样式预览"
        case "help_help" => "  termhelper --help             打印此帮助信息"
        case "help_examples" => "示例:"
        case "help_example_delete" => "  ?? 删除所有 std 开头的文件夹"
        case "help_example_update" => "  ?? 更新系统"
        case "loading_title" => "正在生成命令"
        case "section_query" => "查询"
        case "section_retry" => "重试"
        case "section_model_response" => "模型响应"
        case "waiting_model" => "正在等待模型响应..."
        case "keys_exit" => "Esc / Ctrl-C 退出"
        case "investigate_title" => "需要环境调查"
        case "section_reason" => "原因"
        case "section_diagnostic_commands" => "诊断命令"
        case "running_diagnostics" => "正在运行已授权的诊断命令..."
        case "keys_investigate" => "Space 切换授权  Enter 运行已授权命令  R 全部授权  Esc 退出"
        case "waiting_input" => "等待输入"
        case "section_prompt" => "提示"
        case "section_input" => "输入"
        case "keys_submit_cancel" => "Enter 提交  Esc 取消"
        case "investigation_results" => "环境调查结果:"
        case "investigation_reason" => "调查原因"
        case "no_authorized_diagnostics" => "用户未授权任何诊断命令。"
        case "execute_title" => "命令执行"
        case "status_done" => "已结束"
        case "status_running" => "运行中"
        case "section_command" => "命令"
        case "section_result" => "结果"
        case "field_status" => "状态"
        case "field_exit_code" => "退出码"
        case "section_output" => "输出"
        case "no_output" => "还没有输出。"
        case "keys_execute_done" => "Ctrl-C / Esc / Enter 退出"
        case "keys_execute_running" => "Ctrl-C 中断  Esc 返回"
        case "error_title" => "出现错误"
        case "retryable" => "可重试"
        case "section_recovery" => "恢复"
        case "retry_hint" => "按 Enter/R 重试上一次请求。"
        case "result_title" => "已生成命令"
        case "mode_interactive" => "需要交互"
        case "mode_runnable" => "可运行"
        case "keys_result" => "上/下 选择  PgUp/PgDn 滚动  Home/End 顶部/底部  Enter 确认  R 运行  C 复制  M 修改  Esc 退出"
        case "menu_copy_command" => "复制命令"
        case "menu_copy" => "复制"
        case "menu_modify" => "修改"
        case "menu_exit" => "退出"
        case "menu_run" => "运行"
        case "section_breakdown" => "分解说明"
        case "no_breakdown" => "模型没有提供分解说明。"
        case "field_summary" => "摘要"
        case "section_safety" => "安全性"
        case "no_safety_warnings" => "没有安全警告。"
        case "safety_safe" => "安全"
        case "safety_caution" => "注意"
        case "safety_danger" => "危险"
        case "safety_privilege" => "提权"
        case "section_actions" => "操作"
        case "overlay_title" => "PTY 浮层"
        case "overlay_mode" => "模式"
        case "overlay_round" => "轮次"
        case "overlay_decision" => "决策"
        case "overlay_pending_write" => "待写入"
        case "overlay_reason" => "原因"
        case "pty_confirm" => "确认"
        case "pty_full_auto" => "全自动"
        case "error_no_command" => "当前没有可用命令。"
        case "error_no_investigation" => "当前没有可用的调查请求。"
        case "error_no_clarify" => "当前没有可用的澄清问题。"
        case "prompt_clarify" => "澄清"
        case "prompt_modify" => "修改"
        case "app_title" => "智能终端助手"
        case "screen_thinking" => "智能终端助手 » 思考中"
        case "screen_result" => "智能终端助手 » 结果"
        case "screen_execute" => "智能终端助手 » 执行"
        case "screen_investigate" => "智能终端助手 » 环境调查"
        case "screen_clarify" => "智能终端助手 » 澄清"
        case "screen_modify" => "智能终端助手 » 修改"
        case "screen_error" => "智能终端助手 » 错误"
        case "style_demo_title" => "智能终端助手 » 样式预览"
        case "style_demo_query" => "  列出 /tmp 里的文件"
        case "style_demo_command" => "ls /tmp"
        case "style_demo_summary" => "  摘要：列出临时目录中的文件和子目录。"
        case "style_demo_warning" => "  不修改文件系统。"
        case "local_danger_warning" => "本地安全兜底检测到潜在破坏性命令，请逐项确认路径、通配符和递归参数。"
        case "local_privilege_warning" => "本地安全兜底检测到提权或系统级操作。"
        case "wl_copy_failed" => "wl-copy 执行失败"
        case "xclip_failed" => "xclip 执行失败"
        case "install_wl_clipboard" => "请使用当前发行版的包管理器安装 wl-clipboard"
        case "install_xclip" => "请使用当前发行版的包管理器安装 xclip"
        case "shell_already_installed" => "termhelper 似乎已经安装过了"
        case "shell_installed_to" => "已安装 Shell 集成到"
        case "shell_source_hint" => "请运行: source"
        case "shell_or_restart" => "或重启终端"
        case "shell_rc_missing" => "RC 文件不存在"
        case "shell_marker_missing" => "未找到 termhelper 标记区块"
        case "shell_marker_corrupt" => "标记区块损坏，请手动检查"
        case "shell_uninstalled_from" => "已移除 termhelper Shell 集成:"
        case "screen_pty" => "智能终端助手 » PTY 接管"
        case "pty_create_failed" => "无法创建 PTY 设备"
        case "pty_spawn_failed" => "无法启动命令"
        case "pty_interrupted_by_user" => "用户中断"
        case "pty_round_limit_interrupted" => "达到轮次上限，用户选择中断"
        case "pty_switched_to_manual" => "已切换到手动模式"
        case "pty_command_finished" => "命令执行完毕"
        case "pty_overlay_title" => "PTY 控制面板"
        case "pty_status_waiting" => "等待输出"
        case "pty_status_llm_decision" => "LLM 决策中"
        case "pty_status_awaiting_confirm" => "等待确认"
        case "pty_status_awaiting_input" => "等待输入"
        case "pty_status_throttled" => "节流等待"
        case "pty_status_round_limit" => "轮次上限"
        case "pty_status_finished" => "已完成"
        case "pty_status_interrupted" => "已中断"
        case "pty_confirm_write" => "确认写入"
        case "pty_deny" => "拒绝"
        case "pty_switch_auto" => "切换全自动"
        case "pty_switch_confirm" => "切换确认模式"
        case "pty_continue" => "继续"
        case "pty_manual" => "手动接管"
        case "pty_tokens_used" => "Token 用量"
        case "pty_waiting_output" => "等待命令输出..."
        case "menu_run_pty" => "运行并接管 (PTY)"
        case "keys_pty_default" => "Ctrl-C 中断  ↑↓/PgUp/PgDn 滚动  A 切换全自动  Esc 退出"
        case "keys_pty_awaiting_confirm" => "Enter 确认写入  D 拒绝  A 切换全自动  Esc 中断"
        case "keys_pty_awaiting_input" => "输入后 Enter 提交  Esc 中断"
        case "keys_pty_round_limit" => "Enter 继续  I 中断  M 手动接管  Esc 退出"
        case "pty_round_limit_title" => "已达到轮次上限(%d/%d)"
        case "pty_output_top_marker" => "——— 以下是当前终端输出 ———"
        case "pty_section_terminal" => "终端输出"
        case "pty_section_overlay" => "控制面板"
        case "pty_input_prompt" => "请输入: "
        case "pty_sensitive_input" => "请输入 (敏感信息): "
        case "pty_interrupt" => "中断"
        case _ => key
    }
}

func enText(key: String): String {
    match (key) {
        case "usage_short" => "Usage: termhelper <query> | --install | --uninstall | --help"
        case "try_help" => "Try: termhelper --help"
        case "install_placeholder" => "[phase 1 placeholder] Install shell integration"
        case "uninstall_placeholder" => "[phase 1 placeholder] Uninstall shell integration"
        case "usage_debug" => "Usage: termhelper --debug <query>"
        case "missing_api_key" => "Missing LLM API key. Set LLM_API_KEY / OPENAI_API_KEY, or write it to ~/.config/termhelper/config.json."
        case "help_title" => "termhelper - Linux terminal assistant"
        case "help_desc" => "Convert natural language into executable shell commands with explanations and safety warnings"
        case "help_usage" => "Usage:"
        case "help_query" => "  termhelper <natural language query>  Run a query and open the full-screen TUI"
        case "help_install" => "  termhelper --install                 Install shell integration (alias/def in RC file)"
        case "help_uninstall" => "  termhelper --uninstall               Uninstall shell integration (remove from RC file)"
        case "help_debug" => "  termhelper --debug <query>           CLI debug mode; print LLMResponse JSON"
        case "help_demo" => "  termhelper --tui-demo                Show the colorful TUI style preview"
        case "help_help" => "  termhelper --help                    Print this help"
        case "help_examples" => "Examples:"
        case "help_example_delete" => "  ?? delete all folders starting with std"
        case "help_example_update" => "  ?? update the system"
        case "loading_title" => "Generating command"
        case "section_query" => "Query"
        case "section_retry" => "Retry"
        case "section_model_response" => "Model response"
        case "waiting_model" => "Waiting for model response..."
        case "keys_exit" => "Esc / Ctrl-C exit"
        case "investigate_title" => "Environment investigation required"
        case "section_reason" => "Reason"
        case "section_diagnostic_commands" => "Diagnostic commands"
        case "running_diagnostics" => "Running authorized diagnostic commands..."
        case "keys_investigate" => "Space toggle authorization  Enter run authorized commands  R authorize all  Esc exit"
        case "waiting_input" => "Waiting for input"
        case "section_prompt" => "Prompt"
        case "section_input" => "Input"
        case "keys_submit_cancel" => "Enter submit  Esc cancel"
        case "investigation_results" => "Environment investigation results:"
        case "investigation_reason" => "Investigation reason"
        case "no_authorized_diagnostics" => "The user did not authorize any diagnostic commands."
        case "execute_title" => "Command execution"
        case "status_done" => "Finished"
        case "status_running" => "Running"
        case "section_command" => "Command"
        case "section_result" => "Result"
        case "field_status" => "Status"
        case "field_exit_code" => "Exit code"
        case "section_output" => "Output"
        case "no_output" => "No output yet."
        case "keys_execute_done" => "Ctrl-C / Esc / Enter exit"
        case "keys_execute_running" => "Ctrl-C interrupt  Esc back"
        case "error_title" => "Error"
        case "retryable" => "retryable"
        case "section_recovery" => "Recovery"
        case "retry_hint" => "Press Enter/R to retry the previous request."
        case "result_title" => "Command generated"
        case "mode_interactive" => "Interactive"
        case "mode_runnable" => "Ready"
        case "keys_result" => "Up/Down select  PgUp/PgDn scroll  Home/End top/bottom  Enter confirm  R run  C copy  M modify  Esc exit"
        case "menu_copy_command" => "Copy command"
        case "menu_copy" => "Copy"
        case "menu_modify" => "Modify"
        case "menu_exit" => "Exit"
        case "menu_run" => "Run"
        case "section_breakdown" => "Breakdown"
        case "no_breakdown" => "The model did not provide a breakdown."
        case "field_summary" => "Summary"
        case "section_safety" => "Safety"
        case "no_safety_warnings" => "No safety warnings."
        case "safety_safe" => "Safe"
        case "safety_caution" => "Caution"
        case "safety_danger" => "Danger"
        case "safety_privilege" => "Privilege"
        case "section_actions" => "Actions"
        case "overlay_title" => "PTY overlay"
        case "overlay_mode" => "Mode"
        case "overlay_round" => "Round"
        case "overlay_decision" => "Decision"
        case "overlay_pending_write" => "Pending write"
        case "overlay_reason" => "Reason"
        case "pty_confirm" => "Confirm"
        case "pty_full_auto" => "Full auto"
        case "error_no_command" => "No command is available."
        case "error_no_investigation" => "No investigation request is available."
        case "error_no_clarify" => "No clarification question is available."
        case "prompt_clarify" => "Clarify"
        case "prompt_modify" => "Modify"
        case "app_title" => "Terminal Assistant"
        case "screen_thinking" => "Terminal Assistant » Thinking"
        case "screen_result" => "Terminal Assistant » Result"
        case "screen_execute" => "Terminal Assistant » Execute"
        case "screen_investigate" => "Terminal Assistant » Investigation"
        case "screen_clarify" => "Terminal Assistant » Clarify"
        case "screen_modify" => "Terminal Assistant » Modify"
        case "screen_error" => "Terminal Assistant » Error"
        case "style_demo_title" => "Terminal Assistant » Style Preview"
        case "style_demo_query" => "  List files in /tmp"
        case "style_demo_command" => "ls /tmp"
        case "style_demo_summary" => "  Summary: list files and subdirectories in the temporary directory."
        case "style_demo_warning" => "  Does not modify the file system."
        case "local_danger_warning" => "Local safety fallback detected a potentially destructive command. Check paths, wildcards, and recursive arguments carefully."
        case "local_privilege_warning" => "Local safety fallback detected privilege escalation or system-level operations."
        case "wl_copy_failed" => "wl-copy failed"
        case "xclip_failed" => "xclip failed"
        case "install_wl_clipboard" => "Install wl-clipboard with this distribution's package manager"
        case "install_xclip" => "Install xclip with this distribution's package manager"
        case "shell_already_installed" => "termhelper appears to already be installed"
        case "shell_installed_to" => "Installed shell integration to"
        case "shell_source_hint" => "Run: source"
        case "shell_or_restart" => "or restart the terminal"
        case "shell_rc_missing" => "RC file does not exist"
        case "shell_marker_missing" => "termhelper marker block was not found"
        case "shell_marker_corrupt" => "Marker block is corrupt; check manually"
        case "shell_uninstalled_from" => "Removed termhelper shell integration from:"
        case "screen_pty" => "Terminal Assistant » PTY Agent"
        case "pty_create_failed" => "Failed to create PTY device"
        case "pty_spawn_failed" => "Failed to spawn command"
        case "pty_interrupted_by_user" => "Interrupted by user"
        case "pty_round_limit_interrupted" => "Round limit reached, interrupted by user"
        case "pty_switched_to_manual" => "Switched to manual mode"
        case "pty_command_finished" => "Command finished"
        case "pty_overlay_title" => "PTY Control Panel"
        case "pty_status_waiting" => "Waiting output"
        case "pty_status_llm_decision" => "LLM deciding"
        case "pty_status_awaiting_confirm" => "Awaiting confirm"
        case "pty_status_awaiting_input" => "Awaiting input"
        case "pty_status_throttled" => "Throttled"
        case "pty_status_round_limit" => "Round limit"
        case "pty_status_finished" => "Finished"
        case "pty_status_interrupted" => "Interrupted"
        case "pty_confirm_write" => "Confirm write"
        case "pty_deny" => "Deny"
        case "pty_switch_auto" => "Switch to auto"
        case "pty_switch_confirm" => "Switch to confirm"
        case "pty_continue" => "Continue"
        case "pty_manual" => "Manual takeover"
        case "pty_tokens_used" => "Token usage"
        case "pty_waiting_output" => "Waiting for command output..."
        case "menu_run_pty" => "Run with PTY"
        case "keys_pty_default" => "Ctrl-C interrupt  Up/Down/PgUp/PgDn scroll  A toggle auto  Esc exit"
        case "keys_pty_awaiting_confirm" => "Enter confirm write  D deny  A toggle auto  Esc interrupt"
        case "keys_pty_awaiting_input" => "Type then Enter to submit  Esc to interrupt"
        case "keys_pty_round_limit" => "Enter continue  I interrupt  M manual takeover  Esc exit"
        case "pty_round_limit_title" => "Round limit reached (%d/%d)"
        case "pty_output_top_marker" => "——— Current terminal output below ———"
        case "pty_section_terminal" => "Terminal output"
        case "pty_section_overlay" => "Control panel"
        case "pty_input_prompt" => "Input: "
        case "pty_sensitive_input" => "Input (sensitive): "
        case "pty_interrupt" => "Interrupt"
        case _ => key
    }
}
