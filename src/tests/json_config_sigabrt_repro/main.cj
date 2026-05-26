package termhelper.tests.json_config_sigabrt_repro

import stdx.encoding.json.*

let SAMPLE_CONFIG = """
{
  "provider": "openai_compat",
  "api_key": "fake",
  "base_url": "https://api.deepseek.com/v1",
  "model": "deepseek-v4-pro",
  "timeout_sec": 60,
  "connect_timeout_sec": 10,
  "idle_timeout_sec": 30,
  "spawn_timeout_sec": 300,
  "pty_default_mode": "confirm",
  "pty_max_rounds": 50,
  "pty_min_interval_ms": 2000,
  "pty_min_bytes_threshold": 256,
  "max_retries": 0,
  "base_delay_ms": 1000,
  "max_delay_ms": 2000
}
"""

func jsonGetString(obj: JsonObject, key: String, default: String): String {
    match (obj.get(key)) {
        case Some(jv) => match (jv.kind()) {
            case JsString => jv.asString().getValue()
            case _ => default
        }
        case None => default
    }
}

func jsonGetInt(obj: JsonObject, key: String, default: Int64): Int64 {
    match (obj.get(key)) {
        case Some(jv) => match (jv.kind()) {
            case JsInt => jv.asInt().getValue()
            case _ => default
        }
        case None => default
    }
}

main(): Int64 {
    println("json_config_sigabrt_repro: parse JsonObject and call get().kind()/asString()/asInt()")

    let value = JsonValue.fromStr(SAMPLE_CONFIG)
    let obj = value.asObject()

    let provider = jsonGetString(obj, "provider", "openai_compat")
    let apiKey = jsonGetString(obj, "api_key", "")
    let baseUrl = jsonGetString(obj, "base_url", "")
    let model = jsonGetString(obj, "model", "")
    let timeoutSec = jsonGetInt(obj, "timeout_sec", 60)
    let maxRetries = jsonGetInt(obj, "max_retries", 3)

    println("provider=${provider}")
    println("api_key_len=${apiKey.size}")
    println("base_url=${baseUrl}")
    println("model=${model}")
    println("timeout_sec=${timeoutSec}")
    println("max_retries=${maxRetries}")
    println("done")
    0
}
