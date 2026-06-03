package termhelper

import termhelper.tui.*
import termhelper.infra.*
import termhelper.adapters.*
import termhelper.core.*
import termhelper.util.*
import termhelper.i18n.*
import std.collection.*

/// libc read(2) — 本地声明，用于从 stdin 读取
foreign func read(fd: Int32, buf: CPointer<UInt8>, count: UInt64): Int64

/// 程序入口
/// 用法：
///   termhelper <自然语言查询>    — 执行查询，启动 TUI
///   termhelper --install          — 安装 Shell 集成
///   termhelper --uninstall        — 卸载 Shell 集成
///   termhelper --help             — 打印帮助信息
main(args: Array<String>): Int64 {
    if (args.size == 0) {
        println(uiText("usage_short"))
        println(uiText("try_help"))
        return 1
    }

    let firstArg = args[0]

    // 以 -- 为前缀的参数精确匹配保留词列表
    if (firstArg.startsWith("--")) {
        match (firstArg) {
            case "--install" =>
                println(uiText("install_placeholder"))
                return 0
            case "--uninstall" =>
                println(uiText("uninstall_placeholder"))
                return 0
            case "--debug" =>
                if (args.size < 2) {
                    println(uiText("usage_debug"))
                    return 1
                }
                return runDebug(joinArgsFrom(args, 1))
            case "--tui-demo" => return runTuiDemo()
            case "--help" =>
                printHelp()
                return 0
            case _ =>
                println(uiUnknownArgument(firstArg))
                println(uiText("try_help"))
                return 1
        }
    }

    // 其他所有参数拼接为自然语言查询，进入阶段 5 TUI 主流程。
    return runQueryTui(joinArgs(args))
}

/// 打印帮助信息
func printHelp(): Unit {
    println(uiText("help_title"))
    println(uiText("help_desc"))
    println()
    println(uiText("help_usage"))
    println(uiText("help_query"))
    println(uiText("help_install"))
    println(uiText("help_uninstall"))
    println(uiText("help_debug"))
    println(uiText("help_demo"))
    println(uiText("help_help"))
    println()
    println(uiText("help_examples"))
    println(uiText("help_example_delete"))
    println(uiText("help_example_update"))
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

// ── API Key 交互式配置（定义在调用点之前）──

/// 从 stdin 读取一行（逐字节读取，遇到换行停止）
func readLineFromStdin(): String {
    unsafe {
        let bytes = ArrayList<UInt8>()
        let buf = LibC.malloc<UInt8>(count: 1)
        var i: Int64 = 0
        while (i < 4096) {
            let n = read(0, buf, 1)
            if (n <= 0) { break }
            let b = buf.read(0)
            if (b == b'\n' || b == b'\r') { break }
            bytes.add(b)
            i += 1
        }
        LibC.free(buf)
        String.fromUtf8(bytes.toArray())
    }
}

/// 交互式 API Key 输入（无配置时调用）
func promptApiKeyInteractive(): ?Config {
    println(uiText("api_key_welcome"))
    println(uiText("api_key_instructions"))
    print(uiText("api_key_prompt"))

    let key = readLineFromStdin()
    if (key.size == 0) {
        return None
    }

    // 加载或创建配置，写入 API Key 并保存
    var config = try {
        loadConfig()
    } catch (_: Exception) {
        // 无法加载配置时创建最小配置
        let c = Config()
        c.provider = "openai_compat"
        c.llm.baseUrl = "https://api.openai.com/v1"
        c
    }
    config.llm.apiKey = key.trimAscii()
    saveConfig(config)
    println(uiText("api_key_saved"))
    Some(config)
}

// ── 主流程 ──

func runDebug(query: String): Int64 {
    enableDebugTrace()
    debugTrace("runDebug: start query_size=${query.size}")
    var config = try {
        loadConfig()
    } catch (e: Exception) {
        println(uiConfigLoadFailed(e.message))
        return 1
    }
    debugTrace(
        "runDebug: config loaded provider=${config.provider}, base_url=${config.llm.baseUrl}, model=${config.llm.model}, timeout=${config.llm.timeoutSec}")
    if (needsInteractiveConfig(config)) {
        match (promptApiKeyInteractive()) {
            case Some(newConfig) => config = newConfig
            case None =>
                println(uiText("missing_api_key"))
                return 1
        }
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

func runQueryTui(query: String): Int64 {
    var config = try {
        loadConfig()
    } catch (e: Exception) {
        println(uiConfigLoadFailed(e.message))
        return 1
    }
    if (needsInteractiveConfig(config)) {
        match (promptApiKeyInteractive()) {
            case Some(newConfig) => config = newConfig
            case None =>
                println(uiText("missing_api_key"))
                return 1
        }
    }

    let ctxManager = ContextManager()
    let ctx = ctxManager.load()
    let provider = createProvider(config)
    let session = Session(provider, config, ctx)

    match (runApp(query, session, config)) {
        case Ok(_) => 0
        case Err(e) =>
            println(uiTuiStartFailed(e.message))
            1
    }
}

func runTuiDemo(): Int64 {
    match (runStyleDemo()) {
        case Ok(_) => 0
        case Err(e) =>
            println(uiTuiDemoStartFailed(e.message))
            1
    }
}

func createProvider(config: Config): LLMProvider {
    let providerName = config.provider
    let baseUrl = providerBaseUrl(providerName, config.llm.baseUrl)
    let connectSec = config.llm.connectTimeoutSec
    let readSec = config.llm.timeoutSec
    let idleSec = config.llm.idleTimeoutSec
    debugTrace(
        "createProvider: provider=${providerName}, base_url=${baseUrl}, connect=${connectSec}, read=${readSec}, idle=${idleSec}")
    if (providerName == "anthropic") {
        LLMProvider.fromAnthropic(
            AnthropicProvider(baseUrl, config.llm.apiKey, config.llm.model, connectSec, readSec, idleSec))
    } else if (providerName == "google") {
        LLMProvider.fromGoogle(GoogleProvider(baseUrl, config.llm.apiKey, config.llm.model, connectSec, readSec, idleSec))
    } else {
        LLMProvider.fromOpenAI(
            OpenAICompatProvider(baseUrl, config.llm.apiKey, config.llm.model, connectSec, readSec, idleSec))
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
