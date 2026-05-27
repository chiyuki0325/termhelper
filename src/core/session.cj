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
        debugTrace("Session.runLlm: building request")
        let req = requestBuilder.build(query, history, context, config)
        debugTrace("Session.runLlm: request built, calling provider.chat")
        let chatResp = withLlmRetry(config.retry, { => provider.chat(req) })
        debugTrace("Session.runLlm: provider.chat returned finishReason=${chatResp.finishReason}, content_size=${chatResp.content.size}, tool_calls=${chatResp.toolCalls.size}")
        let parsed = parseStructuredResponse(chatResp)
        debugTrace("Session.runLlm: structured response parsed")
        handleResponse(parsed)
    }

    private func parseStructuredResponse(chatResp: ChatResponse): LLMResponse {
        var jsonText = chatResp.content.trimAscii()
        if (chatResp.toolCalls.size > 0) {
            jsonText = chatResp.toolCalls[0].arguments.trimAscii()
        }

        debugTrace("Session.parseStructuredResponse: json_text_size=${jsonText.size}, json_text=${jsonText}")
        match (parseLLMResponseJson(jsonText)) {
            case Some(resp) =>
                debugTrace("Session.parseStructuredResponse: parse ok")
                resp
            case None =>
                debugTrace("Session.parseStructuredResponse: parse failed")
                LLMResponse.Clarify(ClarifyData("LLM 返回无法解析为 termhelper 结构化响应。原始 finishReason: ${chatResp.finishReason}"))
        }
    }
}
