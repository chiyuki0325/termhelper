package termhelper.core

import termhelper.types.*
import termhelper.adapters.*
import termhelper.infra.*
import termhelper.i18n.*
import termhelper.util.*
import std.collection.*
import std.math.*

// ── 下层动作 ──

/// handleResponse() 返回的 downstream action，由调用方消费
public enum SessionAction {
    | ShowCommand(CommandData) // 展示命令结果
    | RequestInvestigate(InvestigateData) // 请求环境调查
    | AskClarify(ClarifyData) // 请求用户澄清
    | FormatError(String) // JSON/Structured Output 解析失败
    | ProviderError(String) // LLM Provider 不可恢复错误
}

// ── 格式异常 ──

public class FormatException <: Exception {
    public init(message: String) {
        super(message)
    }
}

func makeMessage(role: MessageRole, content: String): Message {
    let m = Message()
    m.role = role
    m.content = content
    m
}

func noRetryNotify(att: Int64, reason: String): Unit {}

public class Session {
    private let provider: LLMProvider
    private let config: Config
    private var context: EnvironmentContext
    private let requestBuilder: RequestBuilder
    private let contextManager: ContextManager
    public let history: ArrayList<Message>

    public init(provider: LLMProvider, config: Config, context: EnvironmentContext) {
        this.provider = provider
        this.config = config
        this.context = context
        this.requestBuilder = RequestBuilder()
        this.contextManager = ContextManager()
        this.history = ArrayList<Message>()
    }

    /// 同步执行 LLM 调用，返回解析后的 LLMResponse。
    /// 若解析失败则抛出 FormatException；重试耗尽则抛出 Exception。
    /// 用于 --debug CLI 等非 TUI 场景。
    public func start(query: String): LLMResponse {
        history.add(makeMessage(MessageRole.User, query))
        return runLlm(query)
    }

    /// 修改指令后重新发起 LLM 调用
    public func modify(instruction: String): LLMResponse {
        history.add(makeMessage(MessageRole.User, instruction))
        return runLlm(instruction)
    }

    /// 处理 LLM 响应，返回下层动作供调用方消费。
    public func handleResponse(response: LLMResponse): SessionAction {
        let checked = applySafetyFallback(response)

        // FR-03/FR-08: 合并环境调查结论
        applyContextUpdates(response)

        history.add(makeMessage(MessageRole.Assistant, llmResponseToJsonString(checked)))
        match (checked) {
            case LLMResponse.Command(data) => SessionAction.ShowCommand(data)
            case LLMResponse.Investigate(data) => SessionAction.RequestInvestigate(data)
            case LLMResponse.Clarify(data) => SessionAction.AskClarify(data)
        }
    }

    public func updateContext(ctx: EnvironmentContext): Unit {
        context = ctx
    }

    /// 合并 InvestigateData 中的上下文更新 delta 并持久化
    private func applyContextUpdates(resp: LLMResponse): Unit {
        match (resp) {
            case LLMResponse.Investigate(data) =>
                if (data.contextUpdates.size > 0) {
                    context = contextManager.update(context, data.contextUpdates)
                    contextManager.save(context)
                }
            case _ => ()
        }
    }

    private func runLlm(query: String): LLMResponse {
        debugTrace("Session.runLlm: building request")
        let req = requestBuilder.build(query, history, context, config)
        debugTrace("Session.runLlm: request built, calling provider.chat")
        let chatResp = withLlmRetry(config.retry, {=> provider.chat(req)}, noRetryNotify)
        debugTrace(
            "Session.runLlm: provider.chat returned finishReason=${chatResp.finishReason}, content_size=${chatResp.content.size}, tool_calls=${chatResp.toolCalls.size}")
        let parsed = parseStructuredResponse(chatResp)
        debugTrace(
            "Session.runLlm: structured response parsed, type=${llmResponseToJsonString(parsed)[0..min(80, llmResponseToJsonString(parsed).size)]}")
        parsed
    }

    /// 严格解析 LLM 响应。失败时抛出 FormatException，不做容错兜底。
    private func parseStructuredResponse(chatResp: ChatResponse): LLMResponse {
        var jsonText = chatResp.content.trimAscii()
        if (chatResp.toolCalls.size > 0) {
            jsonText = chatResp.toolCalls[0].arguments.trimAscii()
        }

        debugTrace("Session.parseStructuredResponse: json_text_size=${jsonText.size}")
        match (parseLLMResponseJson(jsonText)) {
            case Some(resp) =>
                debugTrace("Session.parseStructuredResponse: parse ok")
                resp
            case None =>
                debugTrace("Session.parseStructuredResponse: parse failed, raw=${jsonText}")
                throw FormatException(uiLlmParseFailed(chatResp.finishReason, jsonText.size))
        }
    }
}
