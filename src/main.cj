package termhelper

import termhelper.types.*
import termhelper.tui.*
import termhelper.infra.*
import termhelper.adapters.*
import termhelper.core.*
import termhelper.util.*

/// 程序入口
/// 用法：
///   termhelper <自然语言查询>    — 执行查询，启动 TUI
///   termhelper --install          — 安装 Shell 集成
///   termhelper --uninstall        — 卸载 Shell 集成
///   termhelper --help             — 打印帮助信息
main(args: Array<String>): Int64 {
    if (args.size == 0) {
        println("用法: termhelper <查询> | --install | --uninstall | --help")
        println("尝试: termhelper --help")
        return 1
    }

    let firstArg = args[0]

    // 以 -- 为前缀的参数精确匹配保留词列表
    if (firstArg.startsWith("--")) {
        match (firstArg) {
            case "--install" =>
                println("[阶段 1 占位] 安装 Shell 集成")
                return 0
            case "--uninstall" =>
                println("[阶段 1 占位] 卸载 Shell 集成")
                return 0
            case "--debug" =>
                if (args.size < 2) {
                    println("用法: termhelper --debug <查询>")
                    return 1
                }
                return runDebug(joinArgsFrom(args, 1))
            case "--help" =>
                printHelp()
                return 0
            case _ =>
                println("未知参数: ${firstArg}")
                println("尝试: termhelper --help")
                return 1
        }
    }

    // 其他所有参数拼接为自然语言查询
    let query = joinArgs(args)
    println("查询: ${query}")
    println("[阶段 1] 类型系统初始化完成，TUI 验证待进行")

    // 尝试初始化 TUI（验证 ratatui binding）
    match (initTUI()) {
        case Ok(terminal) =>
            println("[阶段 1] TUI 初始化成功，进入主循环（按 Esc 退出）")
            match (runMainLoop(terminal)) {
                case Ok(_) => ()
                case Err(e) => println("TUI 循环错误: ${e.message}")
            }
            cleanupTUI(terminal)
        case Err(e) =>
            println("[阶段 1] TUI 初始化失败: ${e.message}")
            println("[阶段 1] 回退到 CLI 模式")
            return 1
    }

    return 0
}

/// 打印帮助信息
func printHelp(): Unit {
    println("termhelper — Linux 终端智能助手")
    println("将自然语言转换为可执行的 Shell 命令，辅以说明和安全警告")
    println()
    println("用法:")
    println("  termhelper <自然语言查询>    执行查询，启动全屏 TUI")
    println("  termhelper --install          安装 Shell 集成 (alias/def 写入 RC 文件)")
    println("  termhelper --uninstall        卸载 Shell 集成 (从 RC 文件移除)")
    println("  termhelper --debug <查询>     CLI 调试模式，打印 LLMResponse JSON")
    println("  termhelper --help             打印此帮助信息")
    println()
    println("示例:")
    println("  ?? 删除所有 std 开头的文件夹")
    println("  ?? 更新系统")
}

/// 将参数数组拼接为空格分隔的查询字符串
func joinArgs(args: Array<String>): String {
    joinArgsFrom(args, 0)
}

func joinArgsFrom(args: Array<String>, start: Int64): String {
    var result = ""
    for (i in start..args.size) {
        if (i > start) {
            result += " "
        }
        result += args[i]
    }
    result
}

func runDebug(query: String): Int64 {
    enableDebugTrace()
    debugTrace("runDebug: start query_size=${query.size}")
    let config = try {
        loadConfig()
    } catch (e: Exception) {
        println("配置加载失败: ${e.message}")
        return 1
    }
    debugTrace("runDebug: config loaded provider=${config.provider}, base_url=${config.llm.baseUrl}, model=${config.llm.model}, timeout=${config.llm.timeoutSec}")
    if (needsInteractiveConfig(config)) {
        println("缺少 LLM API Key。请设置 LLM_API_KEY / OPENAI_API_KEY，或写入 ~/.config/termhelper/config.json。")
        return 1
    }

    debugTrace("runDebug: loading context")
    let ctxManager = ContextManager()
    let ctx = ctxManager.load()
    debugTrace("runDebug: creating provider")
    let provider = createProvider(config)
    let session = Session(provider, config, ctx)
    debugTrace("runDebug: calling session.start")
    let response = session.start(query)
    debugTrace("runDebug: session.start returned, serializing response")
    println(llmResponseToJsonString(response))
    debugTrace("runDebug: done")
    return 0
}

func createProvider(config: Config): LLMProvider {
    let providerName = config.provider
    let baseUrl = providerBaseUrl(providerName, config.llm.baseUrl)
    let connectSec = config.llm.connectTimeoutSec
    let readSec = config.llm.timeoutSec
    let idleSec = config.llm.idleTimeoutSec
    debugTrace("createProvider: provider=${providerName}, base_url=${baseUrl}, connect=${connectSec}, read=${readSec}, idle=${idleSec}")
    if (providerName == "anthropic") {
        LLMProvider.fromAnthropic(AnthropicProvider(baseUrl, config.llm.apiKey, config.llm.model, connectSec, readSec, idleSec))
    } else if (providerName == "google") {
        LLMProvider.fromGoogle(GoogleProvider(baseUrl, config.llm.apiKey, config.llm.model, connectSec, readSec, idleSec))
    } else {
        LLMProvider.fromOpenAI(OpenAICompatProvider(baseUrl, config.llm.apiKey, config.llm.model, connectSec, readSec, idleSec))
    }
}

func providerBaseUrl(provider: String, configured: String): String {
    if (provider == "anthropic" && configured == "https://api.openai.com/v1") {
        "https://api.anthropic.com/v1"
    } else if (provider == "google" && configured == "https://api.openai.com/v1") {
        "https://generativelanguage.googleapis.com/v1beta"
    } else {
        configured
    }
}
