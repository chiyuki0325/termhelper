package termhelper.core

import termhelper.adapters.*
import termhelper.infra.*
import std.time.*

public enum RetryDecision {
    | Retryable(String)
    | Fatal(String)
}

/// 带重试的 LLM 调用包装器。
/// - onRetry(attempt, reason): 每次重试前的通知回调（供 TUI 展示状态）
/// - 基于 finishReason 中的 HTTP 状态码分类（非字符串扫描）
public func withLlmRetry(
    config: RetryConfig,
    operation: () -> ChatResponse,
    onRetry: (Int64, String) -> Unit
): ChatResponse {
    var attempt: Int64 = 0
    var last = ChatResponse.empty()
    while (attempt <= config.maxRetries) {
        attempt += 1
        try {
            last = operation()
            match (classifyChatResponse(last)) {
                case RetryDecision.Retryable(reason) =>
                    if (attempt > config.maxRetries) { return last }
                    onRetry(attempt, reason)
                    sleep(Duration.millisecond * retryDelayMs(config, attempt))
                case RetryDecision.Fatal(_) => return last
            }
        } catch (e: Exception) {
            if (attempt > config.maxRetries) {
                return ChatResponse("{}", "error: ${e.message}", Usage.empty())
            }
            onRetry(attempt, e.message)
            sleep(Duration.millisecond * retryDelayMs(config, attempt))
        }
    }
    last
}

/// 基于 HTTP 状态码和 finishReason 分类错误
public func classifyChatResponse(resp: ChatResponse): RetryDecision {
    let reason = resp.finishReason

    // 重试: 5xx (服务端临时故障)
    if (reason.contains("HTTP 502") || reason.contains("HTTP 503") || reason.contains("HTTP 504")) {
        return RetryDecision.Retryable("server error: " + extractHttpCode(reason))
    }
    if (reason.contains("HTTP 500")) {
        return RetryDecision.Retryable("internal server error")
    }

    // 重试: 429 (限流) — Retry-After 由 http client 层处理
    if (reason.contains("HTTP 429")) {
        return RetryDecision.Retryable("rate limited")
    }

    // 重试: 连接/超时
    if (reason.contains("timeout") || reason.contains("Timeout") ||
        reason.contains("connection") || reason.contains("Connection")) {
        return RetryDecision.Retryable(reason)
    }

    // 不可重试: 4xx (客户端错误)
    if (reason.contains("HTTP 400") || reason.contains("HTTP 401") ||
        reason.contains("HTTP 403") || reason.contains("HTTP 404")) {
        return RetryDecision.Fatal("client error: " + extractHttpCode(reason))
    }

    // 未分类的 error → 不可重试
    if (reason.startsWith("error:") || reason.startsWith("HTTP")) {
        return RetryDecision.Fatal(reason)
    }

    // 正常响应 → 不重试
    RetryDecision.Fatal("")
}

/// 指数退避: base * 2^(attempt-1)，cap maxDelay
public func retryDelayMs(config: RetryConfig, attempt: Int64): Int64 {
    var delay = config.baseDelayMs
    var i: Int64 = 1
    while (i < attempt) {
        delay *= 2
        i += 1
    }
    if (delay > config.maxDelayMs) { config.maxDelayMs } else { delay }
}

func extractHttpCode(reason: String): String {
    // "HTTP 502: ..." → "502"
    if (reason.startsWith("HTTP ")) {
        let codeStart = 5
        var codeEnd = codeStart
        while (codeEnd < reason.size && reason[codeEnd] >= b'0' && reason[codeEnd] <= b'9') {
            codeEnd += 1
        }
        reason[codeStart..codeEnd]
    } else {
        reason
    }
}
