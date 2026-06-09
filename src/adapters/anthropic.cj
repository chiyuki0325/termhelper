package termhelper.adapters

import termhelper.types.*
import termhelper.infra.*
import std.collection.ArrayList
import stdx.net.http.*
import stdx.net.tls.*
import stdx.encoding.json.*
import std.io.*
import std.time.*

// ═══════════════════════════════════════════════════════════════
// Anthropic Provider — /v1/messages 协议
// 参考: references/ai/packages/anthropic/src/anthropic-language-model.ts
// ═══════════════════════════════════════════════════════════════

/// Anthropic Provider
public class AnthropicProvider {
    private let baseUrl: String
    private let apiKey: String
    private let model: String
    private let connectTimeoutSec: Int64
    private let readTimeoutSec: Int64
    private let idleTimeoutSec: Int64

    public init(baseUrl: String, apiKey: String, model: String,
                connectTimeoutSec: Int64, readTimeoutSec: Int64, idleTimeoutSec: Int64) {
        this.baseUrl = if (baseUrl.endsWith("/")) { baseUrl[0..(baseUrl.size - 1)] } else { baseUrl }
        this.apiKey = apiKey
        this.model = model
        this.connectTimeoutSec = connectTimeoutSec
        this.readTimeoutSec = readTimeoutSec
        this.idleTimeoutSec = idleTimeoutSec
    }

    /// 非流式对话
    public func chat(req: ChatRequest): ChatResponse {
        let body = buildRequestBody(req, false)
        let url = "${baseUrl}/messages"
        let respText = sendPost(url, body)
        parseChatResponse(respText)
    }

    /// 流式对话
    public func chatStream(req: ChatRequest, onEvent: (StreamEvent) -> Unit): ChatResponse {
        let body = buildRequestBody(req, true)
        let url = "${baseUrl}/messages"
        streamPost(url, body, onEvent)
    }

    /// 流式 tool-calling 对话
    public func chatWithTools(req: ChatRequest, onEvent: (StreamEvent) -> Unit): ChatResponse {
        let body = buildRequestBody(req, true)
        let url = "${baseUrl}/messages"
        streamPost(url, body, onEvent)
    }

    // ── HTTP ──

    private func sendPost(url: String, body: String): String {
        debugTrace("Anthropic.sendPost: build client url=${url}, body_size=${body.size}")
        let client = buildClient(readTimeoutSec)
        let req = HttpRequestBuilder()
            .post()
            .url(url)
            .header("Content-Type", "application/json")
            .header("x-api-key", apiKey)
            .header("anthropic-version", "2023-06-01")
            .body(body)
            .build()
        debugTrace("Anthropic.sendPost: sending request")
        let resp = client.send(req)
        debugTrace("Anthropic.sendPost: got status=${resp.status}")
        if (resp.status != 200) {
            let errBody = StringReader(resp.body).readToEnd()
            debugTrace("Anthropic.sendPost: error body_size=${errBody.size}, closing client")
            client.close()
            let errObj = JsonObject()
            errObj.put("error", JsonString("HTTP ${resp.status}: ${errBody}"))
            return errObj.toJsonString()
        }
        let result = StringReader(resp.body).readToEnd()
        debugTrace("Anthropic.sendPost: response body_size=${result.size}, closing client")
        client.close()
        debugTrace("Anthropic.sendPost: done")
        result
    }

    private func streamPost(url: String, body: String, onEvent: (StreamEvent) -> Unit): ChatResponse {
        debugTrace("Anthropic.streamPost: build client url=${url}, body_size=${body.size}")
        let streamTimeout = if (idleTimeoutSec > readTimeoutSec) { idleTimeoutSec } else { readTimeoutSec * 3 }
        let client = buildClient(streamTimeout)
        let req = HttpRequestBuilder()
            .post()
            .url(url)
            .header("Content-Type", "application/json")
            .header("x-api-key", apiKey)
            .header("anthropic-version", "2023-06-01")
            .body(body)
            .build()
        let resp = client.send(req)

        if (resp.status != 200) {
            let errBody = StringReader(resp.body).readToEnd()
            client.close()
            onEvent(StreamEvent.Error("HTTP ${resp.status}: ${errBody}"))
            return ChatResponse.empty()
        }

        let parser = SseParser()
        let buf = Array<UInt8>(4096, repeat: 0)
        var contentAccum = ""
        var finalUsage = Usage.empty()
        var stopReason = ""

        // Per-block tracking: block index → (type, tool_name, tool_id, partial_json)
        var blocks = ArrayList<(String, String, String, String)>()

        var len = resp.body.read(buf)
        while (len > 0) {
            for (i in 0..len) { parser.feedByte(buf[i]) }

            var evt = parser.tryGetEvent()
            while (true) {
                match (evt) {
                    case Some(e) =>
                        if (e.event == "ping") {
                            () // ignore keepalive
                        } else if (e.event == "message_start") {
                            finalUsage = parseUsageFromEvent(e.data)
                        } else if (e.event == "content_block_start") {
                            // Track new content block using explicit index from event
                            let blockIdx = parseBlockIndex(e.data)
                            let (blockType, toolName, toolId, initialInput) = parseBlockStart(e.data)
                            ensureBlockSlot(blocks, blockIdx)
                            blocks[blockIdx] = (blockType, toolName, toolId, if (blockType == "thinking") { "" } else { initialInput })
                            if (blockType == "tool_use" && toolId.size > 0) {
                                onEvent(StreamEvent.ToolCallStart(toolId))
                                // Emit pre-populated input if present (programmatic tool calling)
                                if (initialInput.size > 0) {
                                    onEvent(StreamEvent.ToolCallDelta(toolId, initialInput))
                                }
                            } else if (blockType == "server_tool_use" && toolId.size > 0) {
                                // Provider-executed tools (code_execution, web_fetch, web_search)
                                onEvent(StreamEvent.ToolCallStart(toolId))
                            } else if (blockType == "thinking" && initialInput.size > 0) {
                                onEvent(StreamEvent.ReasoningChunk(initialInput))
                            }
                        } else if (e.event == "content_block_delta") {
                            let blockIdx = parseBlockIndex(e.data)
                            if (blockIdx >= 0 && blockIdx < blocks.size) {
                                let (blockType, toolName, toolId, partialJson) = blocks[blockIdx]
                                let delta = extractDeltaText(e.data)
                                if (delta.size > 0) {
                                    if (blockType == "text") {
                                        contentAccum += delta
                                        onEvent(StreamEvent.Chunk(delta))
                                    } else if (blockType == "thinking") {
                                        onEvent(StreamEvent.ReasoningChunk(delta))
                                    } else if (blockType == "redacted_thinking") {
                                        () // redacted thinking is intentionally not displayed.
                                    } else if (blockType == "tool_use" || blockType == "server_tool_use") {
                                        let newJson = partialJson + delta
                                        blocks[blockIdx] = (blockType, toolName, toolId, newJson)
                                        onEvent(StreamEvent.ToolCallDelta(toolId, delta))
                                    }
                                }
                            }
                        } else if (e.event == "content_block_stop") {
                            let blockIdx = parseBlockIndex(e.data)
                            if (blockIdx >= 0 && blockIdx < blocks.size) {
                                let (blockType, toolName, toolId, partialJson) = blocks[blockIdx]
                                if ((blockType == "tool_use" || blockType == "server_tool_use") && toolId.size > 0) {
                                    onEvent(StreamEvent.ToolCallEnd(toolId, toolName, partialJson))
                                }
                            }
                        } else if (e.event == "message_delta") {
                            stopReason = extractStopReason(e.data)
                            let u = parseUsageFromEvent(e.data)
                            if (u.inputTokens > 0 || u.outputTokens > 0) {
                                finalUsage = Usage(finalUsage.inputTokens, u.outputTokens)
                            }
                        } else if (e.event == "message_stop") {
                            // Collect tool calls from blocks
                            var toolCalls = ArrayList<ToolCall>()
                            for (bi in 0..blocks.size) {
                                let (blockType, toolName, toolId, partialJson) = blocks[bi]
                                if (blockType == "tool_use" || blockType == "server_tool_use") {
                                    toolCalls.add(ToolCall(toolId, toolName, partialJson))
                                }
                            }
                            onEvent(StreamEvent.Done(finalUsage))
                            client.close()
                            var resultResp = ChatResponse(contentAccum, stopReason, finalUsage)
                            for (bi in 0..toolCalls.size) { resultResp.toolCalls.add(toolCalls[bi]) }
                            return resultResp
                        }
                    case None => break
                }
                evt = parser.tryGetEvent()
            }
            len = resp.body.read(buf)
        }
        client.close()
        onEvent(StreamEvent.Done(finalUsage))
        ChatResponse(contentAccum, stopReason, finalUsage)
    }

    // ── Block tracking helpers ──

    private func ensureBlockSlot(blocks: ArrayList<(String, String, String, String)>, idx: Int64): Unit {
        while (blocks.size <= idx) {
            blocks.add(("", "", "", ""))
        }
    }

    private func parseBlockStart(dataJson: String): (String, String, String, String) {
        try {
            let jv = JsonValue.fromStr(dataJson)
            let root = jv.asObject()
            match (root.get("content_block")) {
                case Some(cbJv) =>
                    let cb = cbJv.asObject()
                    let blockType = jsonGetString(cb, "type", "text")
                    var toolName = ""
                    var toolId = ""
                    var initialInput = ""
                    if (blockType == "tool_use") {
                        toolName = jsonGetString(cb, "name", "")
                        toolId = jsonGetString(cb, "id", "")
                        // Check for pre-populated input (programmatic tool calling)
                        match (cb.get("input")) {
                            case Some(inputJv) =>
                                let inputStr = inputJv.toJsonString()
                                if (inputStr != "{}" && inputStr.size > 0) {
                                    initialInput = inputStr
                                }
                            case None => ()
                        }
                    } else if (blockType == "server_tool_use") {
                        toolName = jsonGetString(cb, "name", "")
                        toolId = jsonGetString(cb, "id", "")
                    } else if (blockType == "thinking") {
                        // thinking block — extract initial thinking text
                        initialInput = jsonGetString(cb, "thinking", "")
                    }
                    (blockType, toolName, toolId, initialInput)
                case None => ("text", "", "", "")
            }
        } catch (_: Exception) { ("text", "", "", "") }
    }

    private func parseBlockIndex(dataJson: String): Int64 {
        try {
            let jv = JsonValue.fromStr(dataJson)
            let root = jv.asObject()
            jsonGetInt(root, "index", -1)
        } catch (_: Exception) { -1 }
    }

    /// Extract text delta from content_block_delta event data
    private func extractDeltaText(dataJson: String): String {
        try {
            let jv = JsonValue.fromStr(dataJson)
            let root = jv.asObject()
            match (root.get("delta")) {
                case Some(dJv) =>
                    let d = dJv.asObject()
                    let deltaType = jsonGetString(d, "type", "")
                    if (deltaType == "text_delta") {
                        jsonGetString(d, "text", "")
                    } else if (deltaType == "input_json_delta") {
                        jsonGetString(d, "partial_json", "")
                    } else if (deltaType == "thinking_delta") {
                        jsonGetString(d, "thinking", "")
                    } else { "" }
                case None => ""
            }
        } catch (_: Exception) { "" }
    }

    /// Parse stop_reason from message_delta event
    private func extractStopReason(dataJson: String): String {
        try {
            let jv = JsonValue.fromStr(dataJson)
            let root = jv.asObject()
            match (root.get("delta")) {
                case Some(dJv) =>
                    let d = dJv.asObject()
                    jsonGetString(d, "stop_reason", "")
                case None => ""
            }
        } catch (_: Exception) { "" }
    }

    /// Parse usage from SSE event data (message_start or message_delta)
    private func parseUsageFromEvent(dataJson: String): Usage {
        try {
            let jv = JsonValue.fromStr(dataJson)
            let root = jv.asObject()
            match (root.get("usage")) {
                case Some(uJv) =>
                    let u = uJv.asObject()
                    let input = jsonGetInt(u, "input_tokens", 0)
                    let output = jsonGetInt(u, "output_tokens", 0)
                    Usage(input, output)
                case None => match (root.get("message")) {
                    case Some(msgJv) =>
                        let msg = msgJv.asObject()
                        match (msg.get("usage")) {
                            case Some(uJv2) =>
                                let u2 = uJv2.asObject()
                                let input = jsonGetInt(u2, "input_tokens", 0)
                                let output = jsonGetInt(u2, "output_tokens", 0)
                                Usage(input, output)
                            case None => Usage.empty()
                        }
                    case None => Usage.empty()
                }
            }
        } catch (_: Exception) { Usage.empty() }
    }

    // ── 请求构造 ──

    private func buildRequestBody(req: ChatRequest, stream: Bool): String {
        let obj = JsonObject()
        obj.put("model", JsonString(if (req.model.size > 0) { req.model } else { model }))
        obj.put("stream", JsonBool(stream))

        // max_tokens (required by Anthropic) — default matches modern Claude models
        match (req.maxTokens) {
            case Some(mt) => obj.put("max_tokens", JsonInt(mt))
            case None => obj.put("max_tokens", JsonInt(128000))
        }

        // system prompt (top-level, not in messages).
        // Use content blocks so Anthropic prompt caching can anchor the stable prefixes.
        if (req.systemPrompts.size > 0) {
            let systemArr = JsonArray()
            for (i in 0..req.systemPrompts.size) {
                systemArr.add(anthropicSystemTextBlock(req.systemPrompts[i], true))
            }
            obj.put("system", systemArr)
        } else {
            match (req.systemPrompt) {
                case Some(sp) =>
                    let systemArr = JsonArray()
                    systemArr.add(anthropicSystemTextBlock(sp, true))
                    obj.put("system", systemArr)
                case None => ()
            }
        }

        // messages — 参照 convert-to-anthropic-prompt.ts 的消息分组逻辑
        // Anthropic API 要求 user+tool 合并为一个 user message，
        // assistant 消息保持独立。
        let msgs = JsonArray()
        var i: Int64 = 0
        while (i < req.messages.size) {
            let m = req.messages[i]
            let role = m.role

            match (role) {
                case MessageRole.System =>
                    // System messages 由 top-level system 字段处理，跳过
                    i += 1
                    continue
                case MessageRole.Assistant =>
                    let mObj = buildAssistantMessage(m)
                    msgs.add(mObj)
                    i += 1
                    continue
                case _ => () // User/Tool → fall through to grouping
            }

            // User / Tool → 合并为一个 user message
            let contentArr = JsonArray()
            while (i < req.messages.size) {
                let cur = req.messages[i]
                var stopGrouping = false
                match (cur.role) {
                    case MessageRole.Assistant => stopGrouping = true
                    case MessageRole.System => stopGrouping = true
                    case MessageRole.User =>
                        let textBlock = JsonObject()
                        textBlock.put("type", JsonString("text"))
                        textBlock.put("text", JsonString(cur.content))
                        contentArr.add(textBlock)
                    case MessageRole.Tool =>
                        // tool 消息 → tool_result block
                        let trBlock = JsonObject()
                        trBlock.put("type", JsonString("tool_result"))
                        match (cur.toolCallId) {
                            case Some(tcId) => trBlock.put("tool_use_id", JsonString(tcId))
                            case None => () // 降级：不带 id
                        }
                        // 检测是否为错误结果
                        if (cur.content.startsWith("error:") || cur.content.contains("\"error\"")) {
                            trBlock.put("is_error", JsonBool(true))
                        }
                        trBlock.put("content", JsonString(cur.content))
                        contentArr.add(trBlock)
                }
                if (stopGrouping) { break }
                i += 1
            }
            let mObj = JsonObject()
            mObj.put("role", JsonString("user"))
            mObj.put("content", contentArr)
            msgs.add(mObj)
        }
        obj.put("messages", msgs)

        // temperature
        match (req.temperature) {
            case Some(t) => obj.put("temperature", JsonFloat(t))
            case None => ()
        }

        // tools
        match (req.tools) {
            case Some(tools) =>
                let toolsArr = JsonArray()
                for (i in 0..tools.size) {
                    let t = tools[i]
                    let tObj = JsonObject()
                    tObj.put("name", JsonString(t.name))
                    tObj.put("description", JsonString(t.description))
                    try {
                        tObj.put("input_schema", JsonValue.fromStr(t.parameters))
                    } catch (_: Exception) {
                        tObj.put("input_schema", JsonObject())
                    }
                    toolsArr.add(tObj)
                }
                obj.put("tools", toolsArr)
            case None => ()
        }

        // tool_choice
        match (req.toolChoice) {
            case Some(tc) =>
                let tcObj = JsonObject()
                match (tc) {
                    case ToolChoice.Auto => tcObj.put("type", JsonString("auto"))
                    case ToolChoice.Required => tcObj.put("type", JsonString("any"))
                    case ToolChoice.NoTool => tcObj.put("type", JsonString("none"))
                }
                obj.put("tool_choice", tcObj)
            case None => ()
        }

        obj.toJsonString()
    }

    /// 构建 assistant message（含可选 tool_use blocks）
    private func buildAssistantMessage(msg: Message): JsonObject {
        let mObj = JsonObject()
        mObj.put("role", JsonString("assistant"))
        let contentArr = JsonArray()

        // text content
        if (msg.content.size > 0) {
            let textBlock = JsonObject()
            textBlock.put("type", JsonString("text"))
            textBlock.put("text", JsonString(msg.content))
            contentArr.add(textBlock)
        }

        // tool_use blocks
        match (msg.toolCalls) {
            case Some(tcs) =>
                for (j in 0..tcs.size) {
                    let tc = tcs[j]
                    let tuBlock = JsonObject()
                    tuBlock.put("type", JsonString("tool_use"))
                    tuBlock.put("id", JsonString(tc.id))
                    tuBlock.put("name", JsonString(tc.name))
                    if (tc.arguments.size > 0) {
                        try {
                            tuBlock.put("input", JsonValue.fromStr(tc.arguments))
                        } catch (_: Exception) {
                            tuBlock.put("input", JsonObject())
                        }
                    } else {
                        tuBlock.put("input", JsonObject())
                    }
                    contentArr.add(tuBlock)
                }
            case None => ()
        }

        mObj.put("content", contentArr)
        mObj
    }

    private func anthropicSystemTextBlock(text: String, cache: Bool): JsonObject {
        let block = JsonObject()
        block.put("type", JsonString("text"))
        block.put("text", JsonString(text))
        if (cache) {
            let cacheControl = JsonObject()
            cacheControl.put("type", JsonString("ephemeral"))
            block.put("cache_control", cacheControl)
        }
        block
    }

    // ── 非流式响应解析 ──

    private func parseChatResponse(jsonText: String): ChatResponse {
        try {
            let jv = JsonValue.fromStr(jsonText)
            let root = jv.asObject()
            match (root.get("content")) {
                case Some(cJv) =>
                    let arr = cJv.asArray()
                    var textContent = ""
                    for (i in 0..arr.size()) {
                        match (arr.get(i)) {
                            case Some(blockJv) =>
                                let block = blockJv.asObject()
                                let blockType = jsonGetString(block, "type", "")
                                if (blockType == "text") {
                                    textContent += jsonGetString(block, "text", "")
                                } else if (blockType == "tool_use") {
                                    // handled below
                                    ()
                                }
                            case None => ()
                        }
                    }

                    let stopReason = jsonGetString(root, "stop_reason", "end_turn")
                    let usage = parseUsage(root)
                    var resp = ChatResponse(textContent, stopReason, usage)

                    // Extract tool_use blocks
                    for (i in 0..arr.size()) {
                        match (arr.get(i)) {
                            case Some(blockJv) =>
                                let block = blockJv.asObject()
                                let blockType = jsonGetString(block, "type", "")
                                if (blockType == "tool_use") {
                                    let toolId = jsonGetString(block, "id", "")
                                    let toolName = jsonGetString(block, "name", "")
                                    match (block.get("input")) {
                                        case Some(inputJv) =>
                                            resp.toolCalls.add(ToolCall(toolId, toolName, inputJv.toJsonString()))
                                        case None => ()
                                    }
                                }
                            case None => ()
                        }
                    }
                    resp
                case None => ChatResponse.empty()
            }
        } catch (_: Exception) {
            ChatResponse.empty()
        }
    }

    private func parseUsage(root: JsonObject): Usage {
        match (root.get("usage")) {
            case Some(uJv) =>
                let u = uJv.asObject()
                let input = jsonGetInt(u, "input_tokens", 0)
                let output = jsonGetInt(u, "output_tokens", 0)
                Usage(input, output)
            case None => Usage.empty()
        }
    }

    private func anthropicRole(role: MessageRole): String {
        match (role) {
            case MessageRole.User => "user"
            case MessageRole.Assistant => "assistant"
            case _ => "user"
        }
    }

    private func buildClient(timeout: Int64): Client {
        let base = ClientBuilder()
            .readTimeout(Duration.second * timeout)
            .writeTimeout(Duration.second * connectTimeoutSec)
        if (baseUrl.startsWith("https://")) {
            base.tlsConfig(TlsClientConfig()).build()
        } else {
            base.build()
        }
    }
}

/// Create a default Anthropic provider instance
public func createAnthropicProvider(apiKey: String, model: String): AnthropicProvider {
    AnthropicProvider("https://api.anthropic.com/v1", apiKey, model, 10, 60, 30)
}
