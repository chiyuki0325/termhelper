package termhelper.adapters

import termhelper.types.*
import std.collection.ArrayList
import stdx.net.http.*
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
    private let timeoutSec: Int64

    public init(baseUrl: String, apiKey: String, model: String, timeoutSec: Int64) {
        this.baseUrl = if (baseUrl.endsWith("/")) { baseUrl[0..(baseUrl.size - 1)] } else { baseUrl }
        this.apiKey = apiKey
        this.model = model
        this.timeoutSec = timeoutSec
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
        let client = ClientBuilder()
            .readTimeout(Duration.second * timeoutSec)
            .writeTimeout(Duration.second * timeoutSec)
            .build()
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
            return "{\"error\": \"HTTP ${resp.status}: ${errBody}\"}"
        }
        let result = StringReader(resp.body).readToEnd()
        client.close()
        result
    }

    private func streamPost(url: String, body: String, onEvent: (StreamEvent) -> Unit): ChatResponse {
        let client = ClientBuilder()
            .readTimeout(Duration.second * (timeoutSec * 3))
            .writeTimeout(Duration.second * timeoutSec)
            .build()
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
                            let (blockType, toolName, toolId) = parseBlockStart(e.data)
                            ensureBlockSlot(blocks, blockIdx)
                            blocks[blockIdx] = (blockType, toolName, toolId, "")
                            if (blockType == "tool_use" && toolId.size > 0) {
                                onEvent(StreamEvent.ToolCallStart(toolId))
                            }
                        } else if (e.event == "content_block_delta") {
                            let blockIdx = parseBlockIndex(e.data)
                            if (blockIdx >= 0 && blockIdx < blocks.size) {
                                let (blockType, toolName, toolId, partialJson) = blocks[blockIdx]
                                let delta = extractDeltaText(e.data)
                                if (delta.size > 0) {
                                    if (blockType == "text" || blockType == "thinking") {
                                        contentAccum += delta
                                        onEvent(StreamEvent.Chunk(delta))
                                    } else if (blockType == "tool_use") {
                                        let newJson = partialJson + delta
                                        blocks[blockIdx] = (blockType, toolName, toolId, newJson)
                                        onEvent(StreamEvent.ToolCallDelta(delta))
                                    }
                                }
                            }
                        } else if (e.event == "content_block_stop") {
                            let blockIdx = parseBlockIndex(e.data)
                            if (blockIdx >= 0 && blockIdx < blocks.size) {
                                let (blockType, toolName, toolId, partialJson) = blocks[blockIdx]
                                if (blockType == "tool_use" && toolId.size > 0) {
                                    onEvent(StreamEvent.ToolCallEnd(toolId, toolName))
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
                                if (blockType == "tool_use") {
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

    private func parseBlockStart(dataJson: String): (String, String, String) {
        try {
            let jv = JsonValue.fromStr(dataJson)
            let root = jv.asObject()
            match (root.get("content_block")) {
                case Some(cbJv) =>
                    let cb = cbJv.asObject()
                    let blockType = jsonGetString(cb, "type", "text")
                    let toolName = if (blockType == "tool_use") { jsonGetString(cb, "name", "") } else { "" }
                    let toolId = if (blockType == "tool_use") { jsonGetString(cb, "id", "") } else { "" }
                    (blockType, toolName, toolId)
                case None => ("text", "", "")
            }
        } catch (_: Exception) { ("text", "", "") }
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

        // system prompt (top-level, not in messages)
        match (req.systemPrompt) {
            case Some(sp) => obj.put("system", JsonString(sp))
            case None => ()
        }

        // messages
        let msgs = JsonArray()
        for (i in 0..req.messages.size) {
            let m = req.messages[i]
            let mObj = JsonObject()
            mObj.put("role", JsonString(anthropicRole(m.role)))
            let contentArr = JsonArray()
            let textBlock = JsonObject()
            textBlock.put("type", JsonString("text"))
            textBlock.put("text", JsonString(m.content))
            contentArr.add(textBlock)
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
}

/// Create a default Anthropic provider instance
public func createAnthropicProvider(apiKey: String, model: String): AnthropicProvider {
    AnthropicProvider("https://api.anthropic.com/v1", apiKey, model, 60)
}
