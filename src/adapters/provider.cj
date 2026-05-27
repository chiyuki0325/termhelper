package termhelper.adapters

import termhelper.types.*
import std.collection.ArrayList

// ═══════════════════════════════════════════════════════════════
// LLM Provider 共享类型 — 不含具体实现
// 各 Provider 实现 chat / chatStream / chatWithTools 三个方法
// ═══════════════════════════════════════════════════════════════

// ── Token 用量 ──

public struct Usage {
    public let inputTokens: Int64
    public let outputTokens: Int64

    public init(inputTokens: Int64, outputTokens: Int64) {
        this.inputTokens = inputTokens
        this.outputTokens = outputTokens
    }

    public static func empty(): Usage { Usage(0, 0) }
}

// ── Tool Calling 类型 ──

/// 工具定义（发给 LLM）
/// parameters 是 JSON Schema 字符串（在 Provider 中序列化为 JSON Object）
public struct ToolDefinition {
    public let name: String
    public let description: String
    public let parameters: String  // JSON Schema 字符串

    public init(name: String, description: String, parameters: String) {
        this.name = name
        this.description = description
        this.parameters = parameters
    }
}

/// LLM 返回的工具调用
public struct ToolCall {
    public let id: String
    public let name: String
    public let arguments: String  // JSON 字符串

    public init(id: String, name: String, arguments: String) {
        this.id = id
        this.name = name
        this.arguments = arguments
    }
}

// ── Tool Choice ──

public enum ToolChoice {
    | Auto
    | Required
    | NoTool
}

// ── Response Format ──

/// ResponseFormat — JSON Schema 存储为字符串（Provider 负责解析/注入）
public enum ResponseFormat {
    | JsonObject                                    // 仅指定返回 JSON
    | JsonSchema(String, String)                    // name + JSON Schema 字符串
}

// ── Chat 请求/响应 ──

/// LLM 请求
public class ChatRequest {
    public let messages: ArrayList<Message>
    public let model: String
    public var temperature: ?Float64
    public var maxTokens: ?Int64
    public var tools: ?ArrayList<ToolDefinition>
    public var toolChoice: ?ToolChoice
    public var responseFormat: ?ResponseFormat
    public var systemPrompt: ?String
    /// "auto" (try json_schema first) | "json_object" (skip json_schema) | "json_schema" (native only)
    public var structuredOutputMode: String
    /// system prompt to use when falling back from json_schema to json_object
    public var fallbackSystemPrompt: ?String

    public init(model: String) {
        this.messages = ArrayList<Message>()
        this.model = model
        this.temperature = None
        this.maxTokens = None
        this.tools = None
        this.toolChoice = None
        this.responseFormat = None
        this.systemPrompt = None
        this.structuredOutputMode = "auto"
        this.fallbackSystemPrompt = None
    }

    public func addUserMessage(content: String): Unit {
        let m = Message()
        m.role = MessageRole.User
        m.content = content
        messages.add(m)
    }

    public func addAssistantMessage(content: String): Unit {
        let m = Message()
        m.role = MessageRole.Assistant
        m.content = content
        messages.add(m)
    }

    public func addToolMessage(content: String): Unit {
        let m = Message()
        m.role = MessageRole.Tool
        m.content = content
        messages.add(m)
    }
}

/// LLM 非流式响应
public struct ChatResponse {
    public let content: String
    public let finishReason: String
    public let usage: Usage
    public let toolCalls: ArrayList<ToolCall>

    public init(content: String, finishReason: String, usage: Usage) {
        this.content = content
        this.finishReason = finishReason
        this.usage = usage
        this.toolCalls = ArrayList<ToolCall>()
    }

    public static func empty(): ChatResponse {
        ChatResponse("", "unknown", Usage.empty())
    }
}

// ── 流式事件 ──

/// SSE 流中的单个事件
public enum StreamEvent {
    | Chunk(String)         // 文本增量
    | ToolCallStart(String) // 工具调用开始 (id)
    | ToolCallDelta(String) // 工具调用参数增量 (JSON delta)
    | ToolCallEnd(String, String)  // 工具调用完成 (id, name)
    | Done(Usage)           // 流结束（含 token 用量）
    | Error(String)         // 流错误
}

// ── 回调类型 ──

/// chatStream 的回调函数类型： (StreamEvent) -> Unit
/// 注意：回调在调用 chatStream 的线程中同步执行，调用方用 spawn 做后台流式

// ── LLMProvider 分派类 ──

/// 统一的 LLM Provider 入口，封装三个具体实现的多态分派
/// 调用方只需持有 LLMProvider，无需感知底层是哪个 provider
public class LLMProvider {
    let openai: ?OpenAICompatProvider
    let anthropic: ?AnthropicProvider
    let google: ?GoogleProvider

    private init(openai: ?OpenAICompatProvider, anthropic: ?AnthropicProvider, google: ?GoogleProvider) {
        this.openai = openai
        this.anthropic = anthropic
        this.google = google
    }

    public static func fromOpenAI(p: OpenAICompatProvider): LLMProvider {
        LLMProvider(Some(p), None, None)
    }
    public static func fromAnthropic(p: AnthropicProvider): LLMProvider {
        LLMProvider(None, Some(p), None)
    }
    public static func fromGoogle(p: GoogleProvider): LLMProvider {
        LLMProvider(None, None, Some(p))
    }

    /// 非流式对话
    public func chat(req: ChatRequest): ChatResponse {
        match (openai) {
            case Some(p) => p.chat(req)
            case None => match (anthropic) {
                case Some(p) => p.chat(req)
                case None => match (google) {
                    case Some(p) => p.chat(req)
                    case None => ChatResponse.empty()
                }
            }
        }
    }

    /// 流式对话
    public func chatStream(req: ChatRequest, onEvent: (StreamEvent) -> Unit): ChatResponse {
        match (openai) {
            case Some(p) => p.chatStream(req, onEvent)
            case None => match (anthropic) {
                case Some(p) => p.chatStream(req, onEvent)
                case None => match (google) {
                    case Some(p) => p.chatStream(req, onEvent)
                    case None => noProviderError(onEvent)
                }
            }
        }
    }

    /// 流式 tool-calling 对话
    public func chatWithTools(req: ChatRequest, onEvent: (StreamEvent) -> Unit): ChatResponse {
        match (openai) {
            case Some(p) => p.chatWithTools(req, onEvent)
            case None => match (anthropic) {
                case Some(p) => p.chatWithTools(req, onEvent)
                case None => match (google) {
                    case Some(p) => p.chatWithTools(req, onEvent)
                    case None => noProviderError(onEvent)
                }
            }
        }
    }

    private func noProviderError(onEvent: (StreamEvent) -> Unit): ChatResponse {
        onEvent(StreamEvent.Error("no provider configured"))
        ChatResponse.empty()
    }
}
