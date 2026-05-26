package termhelper.core

import termhelper.adapters.*
import termhelper.infra.*
import std.time.*

public enum RetryDecision {
    | Retryable(String)
    | Fatal(String)
}

public func withLlmRetry(config: RetryConfig, operation: () -> ChatResponse): ChatResponse {
    var attempt: Int64 = 0
    var last = ChatResponse.empty()
    while (attempt <= config.maxRetries) {
        attempt += 1
        try {
            last = operation()
            match (classifyChatResponse(last)) {
                case RetryDecision.Retryable(_) =>
                    if (attempt > config.maxRetries) { return last }
                    sleep(Duration.millisecond * retryDelayMs(config, attempt))
                case RetryDecision.Fatal(_) => return last
            }
        } catch (e: Exception) {
            if (attempt > config.maxRetries) {
                return ChatResponse("{}", "error: ${e.message}", Usage.empty())
            }
            sleep(Duration.millisecond * retryDelayMs(config, attempt))
        }
    }
    last
}

public func classifyChatResponse(resp: ChatResponse): RetryDecision {
    let text = resp.content + " " + resp.finishReason
    if (retryContainsAny(text, ["HTTP 429", "HTTP 500", "HTTP 502", "HTTP 503", "HTTP 504", "timeout", "Timeout", "connection", "Connection"])) {
        RetryDecision.Retryable(text)
    } else if (retryContainsAny(text, ["HTTP 400", "HTTP 401", "HTTP 403", "SSE", "schema", "JSON parse"])) {
        RetryDecision.Fatal(text)
    } else {
        RetryDecision.Fatal("")
    }
}

public func retryDelayMs(config: RetryConfig, attempt: Int64): Int64 {
    var delay = config.baseDelayMs
    var i: Int64 = 1
    while (i < attempt) {
        delay *= 2
        i += 1
    }
    if (delay > config.maxDelayMs) { config.maxDelayMs } else { delay }
}

func retryContainsAny(text: String, patterns: Array<String>): Bool {
    for (p in patterns) {
        if (text.contains(p)) { return true }
    }
    false
}
