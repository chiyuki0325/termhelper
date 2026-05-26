package termhelper.core

import termhelper.types.*
import termhelper.adapters.*
import termhelper.infra.*
import termhelper.util.*
import std.collection.*

public class Session {
    private let provider: LLMProvider
    private let config: Config
    private var context: EnvironmentContext
    private let requestBuilder: RequestBuilder
    public let history: ArrayList<Message>

    public init(provider: LLMProvider, config: Config, context: EnvironmentContext) {
        this.provider = provider
        this.config = config
        this.context = context
        this.requestBuilder = RequestBuilder()
        this.history = ArrayList<Message>()
    }

    public func start(query: String): LLMResponse {
        history.add(Message(MessageRole.User, query))
        runLlm(query)
    }

    public func modify(instruction: String): LLMResponse {
        history.add(Message(MessageRole.User, instruction))
        runLlm(instruction)
    }

    public func handleResponse(response: LLMResponse): LLMResponse {
        let checked = applySafetyFallback(response)
        history.add(Message(MessageRole.Assistant, llmResponseToJsonString(checked)))
        checked
    }

    public func updateContext(ctx: EnvironmentContext): Unit {
        context = ctx
    }

    private func runLlm(query: String): LLMResponse {
        let req = requestBuilder.build(query, history, context, config)
        let chatResp = withLlmRetry(config.retry, { => provider.chat(req) })
        let parsed = parseStructuredResponse(chatResp)
        handleResponse(parsed)
    }

    private func parseStructuredResponse(chatResp: ChatResponse): LLMResponse {
        var jsonText = chatResp.content.trimAscii()
        if (chatResp.toolCalls.size > 0) {
            jsonText = chatResp.toolCalls[0].arguments.trimAscii()
        }

        match (parseLLMResponseJson(jsonText)) {
            case Some(resp) => resp
            case None =>
                LLMResponse.Clarify(ClarifyData("LLM 返回无法解析为 termhelper 结构化响应。原始 finishReason: ${chatResp.finishReason}"))
        }
    }
}
