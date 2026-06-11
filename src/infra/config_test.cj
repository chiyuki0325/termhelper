package termhelper.infra

import stdx.encoding.json.*

@Test
func parseConfigObjectReadsNestedConfig(): Unit {
    let obj = JsonValue
        .fromStr(
            """
        {
          "provider": "anthropic",
          "llm": {
            "api_key": "file-key",
            "base_url": "https://llm.example/v1",
            "model": "model-a",
            "timeout_sec": 42,
            "connect_timeout_sec": 7,
            "idle_timeout_sec": 9,
            "structured_output_mode": "json_schema"
          },
          "execution": {
            "spawn_timeout_sec": 11,
            "pty_default_mode": "full_auto",
            "pty_max_rounds": 12
          },
          "retry": {
            "max_retries": 5,
            "base_delay_ms": 250,
            "max_delay_ms": 4000
          }
        }
        """)
        .asObject()

    let config = parseConfigObject(obj)

    @Expect(config.provider, "anthropic")
    @Expect(config.llm.apiKey, "file-key")
    @Expect(config.llm.baseUrl, "https://llm.example/v1")
    @Expect(config.llm.model, "model-a")
    @Expect(config.llm.timeoutSec, 42)
    @Expect(config.llm.connectTimeoutSec, 7)
    @Expect(config.llm.idleTimeoutSec, 9)
    @Expect(config.llm.structuredOutputMode, "json_schema")
    @Expect(config.execution.spawnTimeoutSec, 11)
    @Expect(config.execution.ptyDefaultMode, "full_auto")
    @Expect(config.execution.ptyMaxRounds, 12)
    @Expect(config.retry.maxRetries, 5)
    @Expect(config.retry.baseDelayMs, 250)
    @Expect(config.retry.maxDelayMs, 4000)
}

@Test
func parseConfigObjectKeepsFlatConfigCompatibility(): Unit {
    let obj = JsonValue
        .fromStr(
            """
        {
          "provider": "openai_compat",
          "api_key": "flat-key",
          "base_url": "https://flat.example/v1",
          "model": "flat-model",
          "timeout_sec": 33,
          "spawn_timeout_sec": 44,
          "pty_default_mode": "full_auto",
          "pty_max_rounds": 9,
          "max_retries": 6,
          "base_delay_ms": 300,
          "max_delay_ms": 9000
        }
        """)
        .asObject()

    let config = parseConfigObject(obj)

    @Expect(config.llm.apiKey, "flat-key")
    @Expect(config.llm.baseUrl, "https://flat.example/v1")
    @Expect(config.llm.model, "flat-model")
    @Expect(config.llm.timeoutSec, 33)
    @Expect(config.execution.spawnTimeoutSec, 44)
    @Expect(config.execution.ptyDefaultMode, "full_auto")
    @Expect(config.execution.ptyMaxRounds, 9)
    @Expect(config.retry.maxRetries, 6)
    @Expect(config.retry.baseDelayMs, 300)
    @Expect(config.retry.maxDelayMs, 9000)
}

@Test
func configToNestedJsonWritesNestedShape(): Unit {
    let config = Config()
    config.provider = "google"
    config.llm.apiKey = "nested-key"
    config.llm.model = "gemini"
    config.execution.ptyMaxRounds = 77
    config.retry.maxRetries = 8

    let obj = configToNestedJson(config)
    let llm = obj.get("llm").getOrThrow().asObject()
    let execution = obj.get("execution").getOrThrow().asObject()
    let retry = obj.get("retry").getOrThrow().asObject()

    @Expect(obj.get("provider").getOrThrow().asString().getValue(), "google")
    @Expect(obj.containsKey("api_key"), false)
    @Expect(llm.get("api_key").getOrThrow().asString().getValue(), "nested-key")
    @Expect(llm.get("model").getOrThrow().asString().getValue(), "gemini")
    @Expect(execution.get("pty_max_rounds").getOrThrow().asInt().getValue(), 77)
    @Expect(retry.get("max_retries").getOrThrow().asInt().getValue(), 8)
}

@Test
func needsInteractiveConfigReflectsApiKeyPresence(): Unit {
    let missing = Config()
    let present = Config()
    present.llm.apiKey = "configured"

    @Expect(needsInteractiveConfig(missing), true)
    @Expect(needsInteractiveConfig(present), false)
}
