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
    private let lastInvestigationSources: ArrayList<String>
    public let history: ArrayList<Message>

    public init(provider: LLMProvider, config: Config, context: EnvironmentContext) {
        this.provider = provider
        this.config = config
        this.context = context
        this.requestBuilder = RequestBuilder()
        this.contextManager = ContextManager()
        this.lastInvestigationSources = ArrayList<String>()
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

    /// 流式 LLM 调用，通过 onChunk 回调发送增量文本给 TUI
    public func startStream(query: String, onChunk: (String) -> Unit): LLMResponse {
        history.add(makeMessage(MessageRole.User, query))
        return runLlmStream(query, onChunk)
    }

    /// 流式修改指令后重新发起 LLM 调用
    public func modifyStream(instruction: String, onChunk: (String) -> Unit): LLMResponse {
        history.add(makeMessage(MessageRole.User, instruction))
        return runLlmStream(instruction, onChunk)
    }

    /// 处理 LLM 响应，返回下层动作供调用方消费。
    public func handleResponse(response: LLMResponse): SessionAction {
        let checked = applySafetyFallback(response)

        // FR-03/FR-08: 合并环境调查结论
        applyContextUpdates(response)
        applyFactEdits(checked)

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

    public func setInvestigationSources(commands: ArrayList<String>): Unit {
        lastInvestigationSources.clear()
        for (cmd in commands) {
            lastInvestigationSources.add(cmd)
        }
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

    private func applyFactEdits(resp: LLMResponse): Unit {
        match (resp) {
            case LLMResponse.Command(data) =>
                if (data.factEdits.size > 0) {
                    context = contextManager.applyFactEdits(context, data.factEdits, lastInvestigationSources)
                    contextManager.save(context)
                }
                if (lastInvestigationSources.size > 0) {
                    lastInvestigationSources.clear()
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
        debugTrace("Session.runLlm: structured response parsed, preview=${safePreview(llmResponseToJsonString(parsed), 80)}")
        parsed
    }

    /// 流式 LLM 调用：只把 reasoning/thinking 增量转发给 Loading 屏。
    private func runLlmStream(query: String, onChunk: (String) -> Unit): LLMResponse {
        debugTrace("Session.runLlmStream: building request")
        let req = requestBuilder.build(query, history, context, config)
        debugTrace("Session.runLlmStream: calling provider.chatStream")
        let chatResp = provider.chatStream(req, { event: StreamEvent =>
            match (event) {
                case StreamEvent.ReasoningChunk(text) => onChunk(text)
                case _ => ()
            }
        })
        debugTrace(
            "Session.runLlmStream: finished, finishReason=${chatResp.finishReason}, content_size=${chatResp.content.size}")
        // 流式完成后解析结构化响应（复用相同的 parse 逻辑）
        parseStructuredResponse(chatResp)
    }

    private func safePreview(text: String, maxRunes: Int64): String {
        var result = ""
        var count: Int64 = 0
        for (r in text.runes()) {
            if (count >= maxRunes) {
                result += "..."
                return result
            }
            result += String(r)
            count++
        }
        result
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
