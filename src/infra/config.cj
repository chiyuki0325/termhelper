package termhelper.infra

import naivejson.macros.*
import naivejson.schema.*
import naivejson.schema.model.*
import naivejson.schema.render.*
import std.fs.*
import stdx.encoding.json.*
import stdx.serialization.serialization.DataModel
import stdx.serialization.serialization.DataModelStruct
import stdx.serialization.serialization.DataModelException
import stdx.serialization.serialization.Serializable
import stdx.serialization.serialization.field

@JsonAdapter
public class LlmConfig {
    @JsonName["api_key"]
    public var apiKey: String = ""
    @JsonName["base_url"]
    public var baseUrl: String = "https://api.openai.com/v1"
    public var model: String = "gpt-4o"
    @JsonName["timeout_sec"]
    public var timeoutSec: Int64 = 60
    @JsonName["connect_timeout_sec"]
    public var connectTimeoutSec: Int64 = 10
    @JsonName["idle_timeout_sec"]
    public var idleTimeoutSec: Int64 = 30
    @JsonName["structured_output_mode"]
    public var structuredOutputMode: String = "auto"
}

@JsonAdapter
public class ExecConfig {
    @JsonName["spawn_timeout_sec"]
    public var spawnTimeoutSec: Int64 = 300
    @JsonName["pty_default_mode"]
    public var ptyDefaultMode: String = "confirm"
    @JsonName["pty_max_rounds"]
    public var ptyMaxRounds: Int64 = 50
    @JsonName["pty_min_interval_ms"]
    public var ptyMinIntervalMs: Int64 = 2000
    @JsonName["pty_min_bytes_threshold"]
    public var ptyMinBytesThreshold: Int64 = 256
}

@JsonAdapter
public class RetryConfig {
    @JsonName["max_retries"]
    public var maxRetries: Int64 = 3
    @JsonName["base_delay_ms"]
    public var baseDelayMs: Int64 = 1000
    @JsonName["max_delay_ms"]
    public var maxDelayMs: Int64 = 16000
}

@JsonAdapter
public class Config {
    public var version: Int64 = 1
    public var provider: String = "openai_compat"
    public var llm: LlmConfig = LlmConfig()
    public var execution: ExecConfig = ExecConfig()
    public var retry: RetryConfig = RetryConfig()
}

// ── 加载（含自动创建）──

public func loadConfig(): Config {
    let config = parseConfigFile()
    applyEnvOverrides(config)
    config
}

func parseConfigFile(): Config {
    let configDir = termhelperConfigDir()
    let configPath = termhelperConfigPath()
    let p = Path(configPath)

    let dirP = Path(configDir)
    if (!exists(dirP)) {
        Directory.create(dirP, recursive: true)
    }

    if (exists(p)) {
        restrictFileToOwner(configPath)
        let raw = readFileString(configPath)
        let jv = try {
            JsonValue.fromStr(raw)
        } catch (e: Exception) {
            throw Exception("配置文件 JSON 解析失败: ${configPath}: ${e.message}")
        }
        let obj = try {
            jv.asObject()
        } catch (_: Exception) {
            throw Exception("配置文件必须是 JSON Object: ${configPath}")
        }
        let config = parseConfigObject(obj)
        debugTrace("loadConfig: parsed provider=${config.provider}, base_url=${config.llm.baseUrl}, model=${config.llm.model}")
        saveConfig(config)
        return config
    } else {
        let config = Config()
        saveConfig(config)
        return config
    }
}

func parseConfigObject(obj: JsonObject): Config {
    let config = Config()
    config.provider = jsonGetString(obj, "provider", config.provider)

    // 嵌套格式
    match (obj.get("llm")) {
        case Some(llmJv) =>
            try { parseLlmInto(config.llm, llmJv.asObject()) } catch (_: Exception) { () }
        case None => ()
    }
    match (obj.get("execution")) {
        case Some(execJv) =>
            try { parseExecInto(config.execution, execJv.asObject()) } catch (_: Exception) { () }
        case None => ()
    }
    match (obj.get("retry")) {
        case Some(retryJv) =>
            try { parseRetryInto(config.retry, retryJv.asObject()) } catch (_: Exception) { () }
        case None => ()
    }

    // 扁平格式兼容
    if (jsonGetString(obj, "api_key", "").size > 0 || jsonGetInt(obj, "timeout_sec", -1) >= 0) {
        parseLlmInto(config.llm, obj)
        parseExecInto(config.execution, obj)
        parseRetryInto(config.retry, obj)
    }

    config
}

func parseLlmInto(llm: LlmConfig, obj: JsonObject): Unit {
    llm.apiKey = jsonGetString(obj, "api_key", llm.apiKey)
    llm.baseUrl = jsonGetString(obj, "base_url", llm.baseUrl)
    llm.model = jsonGetString(obj, "model", llm.model)
    llm.timeoutSec = jsonGetInt(obj, "timeout_sec", llm.timeoutSec)
    llm.connectTimeoutSec = jsonGetInt(obj, "connect_timeout_sec", llm.connectTimeoutSec)
    llm.idleTimeoutSec = jsonGetInt(obj, "idle_timeout_sec", llm.idleTimeoutSec)
    llm.structuredOutputMode = jsonGetString(obj, "structured_output_mode", llm.structuredOutputMode)
}

func parseExecInto(exec: ExecConfig, obj: JsonObject): Unit {
    exec.spawnTimeoutSec = jsonGetInt(obj, "spawn_timeout_sec", exec.spawnTimeoutSec)
    exec.ptyDefaultMode = jsonGetString(obj, "pty_default_mode", exec.ptyDefaultMode)
    exec.ptyMaxRounds = jsonGetInt(obj, "pty_max_rounds", exec.ptyMaxRounds)
    exec.ptyMinIntervalMs = jsonGetInt(obj, "pty_min_interval_ms", exec.ptyMinIntervalMs)
    exec.ptyMinBytesThreshold = jsonGetInt(obj, "pty_min_bytes_threshold", exec.ptyMinBytesThreshold)
}

func parseRetryInto(retry: RetryConfig, obj: JsonObject): Unit {
    retry.maxRetries = jsonGetInt(obj, "max_retries", retry.maxRetries)
    retry.baseDelayMs = jsonGetInt(obj, "base_delay_ms", retry.baseDelayMs)
    retry.maxDelayMs = jsonGetInt(obj, "max_delay_ms", retry.maxDelayMs)
}

func applyEnvOverrides(config: Config): Unit {
    if (config.provider == "anthropic") {
        let key = envGetOrDefault("ANTHROPIC_API_KEY", "")
        if (key.size > 0) { config.llm.apiKey = key }
    }
    if (config.provider == "google") {
        let key = envGetOrDefault("GOOGLE_API_KEY", "")
        if (key.size > 0) { config.llm.apiKey = key }
    }
    let llmKey = envGetOrDefault("LLM_API_KEY", "")
    if (llmKey.size > 0) { config.llm.apiKey = llmKey }
    let openaiKey = envGetOrDefault("OPENAI_API_KEY", "")
    if (openaiKey.size > 0 && config.llm.apiKey.size == 0) { config.llm.apiKey = openaiKey }
}

// ── 交互式 API Key ──

public func setApiKey(key: String): Unit {
    var config = loadConfig()
    config.llm.apiKey = key
    saveConfig(config)
}

public func needsInteractiveConfig(config: Config): Bool {
    config.llm.apiKey.size == 0
}

// ── 保存（嵌套格式）──

public func saveConfig(config: Config): Unit {
    let configPath = termhelperConfigPath()
    let obj = configToNestedJson(config)
    writeFileString(configPath, obj.toJsonString())
    restrictFileToOwner(configPath)
}

func configToNestedJson(config: Config): JsonObject {
    let obj = JsonObject()
    obj.put("version", JsonInt(config.version))
    obj.put("provider", JsonString(config.provider))

    let llmObj = JsonObject()
    llmObj.put("api_key", JsonString(config.llm.apiKey))
    llmObj.put("base_url", JsonString(config.llm.baseUrl))
    llmObj.put("model", JsonString(config.llm.model))
    llmObj.put("timeout_sec", JsonInt(config.llm.timeoutSec))
    llmObj.put("connect_timeout_sec", JsonInt(config.llm.connectTimeoutSec))
    llmObj.put("idle_timeout_sec", JsonInt(config.llm.idleTimeoutSec))
    llmObj.put("structured_output_mode", JsonString(config.llm.structuredOutputMode))
    obj.put("llm", llmObj)

    let execObj = JsonObject()
    execObj.put("spawn_timeout_sec", JsonInt(config.execution.spawnTimeoutSec))
    execObj.put("pty_default_mode", JsonString(config.execution.ptyDefaultMode))
    execObj.put("pty_max_rounds", JsonInt(config.execution.ptyMaxRounds))
    execObj.put("pty_min_interval_ms", JsonInt(config.execution.ptyMinIntervalMs))
    execObj.put("pty_min_bytes_threshold", JsonInt(config.execution.ptyMinBytesThreshold))
    obj.put("execution", execObj)

    let retryObj = JsonObject()
    retryObj.put("max_retries", JsonInt(config.retry.maxRetries))
    retryObj.put("base_delay_ms", JsonInt(config.retry.baseDelayMs))
    retryObj.put("max_delay_ms", JsonInt(config.retry.maxDelayMs))
    obj.put("retry", retryObj)

    obj
}

// ── 辅助 ──

func jsonGetString(obj: JsonObject, key: String, default: String): String {
    match (obj.get(key)) {
        case Some(jv) => match (jv.kind()) { case JsString => jv.asString().getValue(); case _ => default }
        case None => default
    }
}
func jsonGetInt(obj: JsonObject, key: String, default: Int64): Int64 {
    match (obj.get(key)) {
        case Some(jv) => match (jv.kind()) { case JsInt => jv.asInt().getValue(); case _ => default }
        case None => default
    }
}
