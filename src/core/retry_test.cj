package termhelper.core

import termhelper.adapters.*
import termhelper.infra.*

@Test
func classifyChatResponseMarksRateLimitAndServerErrorsRetryable(): Unit {
    expectRetryable("HTTP 429: too many requests")
    expectRetryable("HTTP 500: internal error")
    expectRetryable("HTTP 502: bad gateway")
    expectRetryable("HTTP 503: unavailable")
    expectRetryable("HTTP 504: gateway timeout")
}

@Test
func classifyChatResponseMarksTimeoutAndConnectionErrorsRetryable(): Unit {
    expectRetryable("timeout while reading response")
    expectRetryable("Connection reset by peer")
}

@Test
func classifyChatResponseMarksClientErrorsAndNormalResponsesFatal(): Unit {
    expectFatal("HTTP 400: invalid request")
    expectFatal("HTTP 401: unauthorized")
    expectFatal("HTTP 403: forbidden")
    expectFatal("HTTP 404: not found")
    expectFatal("stop")
}

@Test
func retryDelayMsUsesExponentialBackoffWithCap(): Unit {
    let config = RetryConfig()
    config.baseDelayMs = 100
    config.maxDelayMs = 350

    @Expect(retryDelayMs(config, 1), 100)
    @Expect(retryDelayMs(config, 2), 200)
    @Expect(retryDelayMs(config, 3), 350)
    @Expect(retryDelayMs(config, 4), 350)
}

func expectRetryable(reason: String): Unit {
    match (classifyChatResponse(ChatResponse("{}", reason, Usage.empty()))) {
        case RetryDecision.Retryable(_) => ()
        case RetryDecision.Fatal(_) => @Fail("expected retryable: ${reason}")
    }
}

func expectFatal(reason: String): Unit {
    match (classifyChatResponse(ChatResponse("{}", reason, Usage.empty()))) {
        case RetryDecision.Fatal(_) => ()
        case RetryDecision.Retryable(_) => @Fail("expected fatal: ${reason}")
    }
}
