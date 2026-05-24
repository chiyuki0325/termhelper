package termhelper.infra

import std.fs.*
import stdx.encoding.json.*

// ═══════════════════════════════════════════════════════════════
// 配置管理 — env → JSON 文件 → 默认值 三层 fallback
// ═══════════════════════════════════════════════════════════════

public struct LlmConfig {
    public var apiKey: String
    public var baseUrl: String
    public var model: String
    public var timeoutSec: Int64
    public var connectTimeoutSec: Int64
    public var idleTimeoutSec: Int64

    public init(apiKey: String, baseUrl: String, model: String,
                timeoutSec: Int64, connectTimeoutSec: Int64, idleTimeoutSec: Int64) {
        this.apiKey = apiKey; this.baseUrl = baseUrl; this.model = model
        this.timeoutSec = timeoutSec; this.connectTimeoutSec = connectTimeoutSec
        this.idleTimeoutSec = idleTimeoutSec
    }
    public static func defaults(): LlmConfig {
        LlmConfig("", "https://api.openai.com/v1", "gpt-4o", 60, 10, 30)
    }
}

public struct ExecConfig {
    public var spawnTimeoutSec: Int64
    public var ptyDefaultMode: String
    public var ptyMaxRounds: Int64
    public var ptyMinIntervalMs: Int64
    public var ptyMinBytesThreshold: Int64

    public init(spawnTimeoutSec: Int64, ptyDefaultMode: String,
                ptyMaxRounds: Int64, ptyMinIntervalMs: Int64, ptyMinBytesThreshold: Int64) {
        this.spawnTimeoutSec = spawnTimeoutSec; this.ptyDefaultMode = ptyDefaultMode
        this.ptyMaxRounds = ptyMaxRounds; this.ptyMinIntervalMs = ptyMinIntervalMs
        this.ptyMinBytesThreshold = ptyMinBytesThreshold
    }
    public static func defaults(): ExecConfig {
        ExecConfig(300, "confirm", 50, 2000, 256)
    }
}

public struct RetryConfig {
    public var maxRetries: Int64
    public var baseDelayMs: Int64
    public var maxDelayMs: Int64

    public init(maxRetries: Int64, baseDelayMs: Int64, maxDelayMs: Int64) {
        this.maxRetries = maxRetries; this.baseDelayMs = baseDelayMs
        this.maxDelayMs = maxDelayMs
    }
    public static func defaults(): RetryConfig {
        RetryConfig(3, 1000, 16000)
    }
}

public struct Config {
    public var version: Int64
    public var provider: String
    public var llm: LlmConfig
    public var execution: ExecConfig
    public var retry: RetryConfig

    public init(provider: String, llm: LlmConfig, execution: ExecConfig, retry: RetryConfig) {
        this.version = 1; this.provider = provider
        this.llm = llm; this.execution = execution; this.retry = retry
    }
    public static func defaults(): Config {
        Config("openai_compat", LlmConfig.defaults(), ExecConfig.defaults(), RetryConfig.defaults())
    }
}

let CONFIG_DIR: String = "${envGetHome()}/.config/termhelper"

// ── 加载 ──

public func loadConfig(): Config {
    var config = Config.defaults()
    let configPath = "${CONFIG_DIR}/config.json"

    // 1. JSON 文件
    let p = Path(configPath)
    if (exists(p)) {
        try {
            let jv = readJsonFileAtomic(configPath)
            let obj = jv.asObject()
            config.provider = jsonGetString(obj, "provider", "openai_compat")
            config.llm.apiKey = jsonGetString(obj, "api_key", "")
            config.llm.baseUrl = jsonGetString(obj, "base_url", config.llm.baseUrl)
            config.llm.model = jsonGetString(obj, "model", config.llm.model)
            config.llm.timeoutSec = jsonGetInt(obj, "timeout_sec", config.llm.timeoutSec)
            config.llm.connectTimeoutSec = jsonGetInt(obj, "connect_timeout_sec", config.llm.connectTimeoutSec)
            config.llm.idleTimeoutSec = jsonGetInt(obj, "idle_timeout_sec", config.llm.idleTimeoutSec)
            config.execution.spawnTimeoutSec = jsonGetInt(obj, "spawn_timeout_sec", config.execution.spawnTimeoutSec)
            config.execution.ptyMaxRounds = jsonGetInt(obj, "pty_max_rounds", config.execution.ptyMaxRounds)
            config.execution.ptyMinIntervalMs = jsonGetInt(obj, "pty_min_interval_ms", config.execution.ptyMinIntervalMs)
            config.execution.ptyMinBytesThreshold = jsonGetInt(obj, "pty_min_bytes_threshold", config.execution.ptyMinBytesThreshold)
            let mode = jsonGetString(obj, "pty_default_mode", "")
            if (mode.size > 0) { config.execution.ptyDefaultMode = mode }
            config.retry.maxRetries = jsonGetInt(obj, "max_retries", config.retry.maxRetries)
            config.retry.baseDelayMs = jsonGetInt(obj, "base_delay_ms", config.retry.baseDelayMs)
            config.retry.maxDelayMs = jsonGetInt(obj, "max_delay_ms", config.retry.maxDelayMs)
        } catch (_: Exception) { /* 文件损坏，用默认值 */ }
    }

    // 2. 环境变量覆盖
    let apiKey = envGetOrDefault("LLM_API_KEY", "")
    if (apiKey.size > 0) { config.llm.apiKey = apiKey }

    let openaiKey = envGetOrDefault("OPENAI_API_KEY", "")
    if (openaiKey.size > 0 && config.llm.apiKey.size == 0) { config.llm.apiKey = openaiKey }

    config
}

// ── 保存 ──

public func saveConfig(config: Config): Unit {
    let obj = JsonObject()
    obj.put("version", JsonInt(config.version))
    obj.put("provider", JsonString(config.provider))
    obj.put("api_key", JsonString(config.llm.apiKey))
    obj.put("base_url", JsonString(config.llm.baseUrl))
    obj.put("model", JsonString(config.llm.model))
    obj.put("timeout_sec", JsonInt(config.llm.timeoutSec))
    obj.put("connect_timeout_sec", JsonInt(config.llm.connectTimeoutSec))
    obj.put("idle_timeout_sec", JsonInt(config.llm.idleTimeoutSec))
    obj.put("spawn_timeout_sec", JsonInt(config.execution.spawnTimeoutSec))
    obj.put("pty_default_mode", JsonString(config.execution.ptyDefaultMode))
    obj.put("pty_max_rounds", JsonInt(config.execution.ptyMaxRounds))
    obj.put("pty_min_interval_ms", JsonInt(config.execution.ptyMinIntervalMs))
    obj.put("pty_min_bytes_threshold", JsonInt(config.execution.ptyMinBytesThreshold))
    obj.put("max_retries", JsonInt(config.retry.maxRetries))
    obj.put("base_delay_ms", JsonInt(config.retry.baseDelayMs))
    obj.put("max_delay_ms", JsonInt(config.retry.maxDelayMs))

    let configPath = "${CONFIG_DIR}/config.json"
    writeJsonFileAtomic(configPath, obj)
}

public func needsInteractiveConfig(config: Config): Bool {
    config.llm.apiKey.size == 0
}

// ── 辅助 ──

func jsonGetString(obj: JsonObject, key: String, default: String): String {
    match (obj.get(key)) {
        case Some(jv) =>
            match (jv.kind()) {
                case JsString => jv.asString().getValue()
                case _ => default
            }
        case None => default
    }
}

func jsonGetInt(obj: JsonObject, key: String, default: Int64): Int64 {
    match (obj.get(key)) {
        case Some(jv) =>
            match (jv.kind()) {
                case JsInt => jv.asInt().getValue()
                case _ => default
            }
        case None => default
    }
}
