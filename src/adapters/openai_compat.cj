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
// OpenAI Compatible Provider — /v1/chat/completions 协议
// 兼容 OpenAI / DeepSeek / Moonshot 等兼容服务
// ═══════════════════════════════════════════════════════════════

/// OpenAI 兼容 Provider
public class OpenAICompatProvider {
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
        let parsed = chatCollect(req)
        if (shouldFallbackToJsonObject(req, parsed)) {
            debugTrace("OpenAICompat.chat: json_schema unavailable, retrying with json_object")
            req.responseFormat = Some(ResponseFormat.JsonObject)
            return chatCollect(req)
        }
        parsed
    }

    /// 流式对话（在当前线程同步调用回调，由调用方 spawn 管理后台执行）
    public func chatStream(req: ChatRequest, onEvent: (StreamEvent) -> Unit): ChatResponse {
        let body = buildRequestBody(req, true)
        let url = "${baseUrl}/chat/completions"
        streamPost(url, body, onEvent)
    }

    /// 流式 tool-calling 对话
    public func chatWithTools(req: ChatRequest, onEvent: (StreamEvent) -> Unit): ChatResponse {
        let body = buildRequestBody(req, true)  // stream=true for tool calls too
        let url = "${baseUrl}/chat/completions"
        streamPost(url, body, onEvent)
    }

    private func chatCollect(req: ChatRequest): ChatResponse {
        let body = buildRequestBody(req, true)
        let url = "${baseUrl}/chat/completions"
        streamPost(url, body, { _ => () })
    }

    // ── HTTP ──

    private func sendPost(url: String, body: String): String {
        debugTrace("OpenAICompat.sendPost: build client url=${url}, body_size=${body.size}")
        let client = if (url.startsWith("https://")) {
            let tlsConfig = TlsClientConfig()
            ClientBuilder()
                .tlsConfig(tlsConfig)
                .readTimeout(Duration.second * timeoutSec)
                .writeTimeout(Duration.second * timeoutSec)
                .build()
        } else {
            ClientBuilder()
                .readTimeout(Duration.second * timeoutSec)
                .writeTimeout(Duration.second * timeoutSec)
                .build()
        }
        let req = HttpRequestBuilder()
            .post()
            .url(url)
            .header("Content-Type", "application/json")
            .header("Authorization", "Bearer " + apiKey)
            .body(body)
            .build()
        debugTrace("OpenAICompat.sendPost: sending request")
        let resp = client.send(req)
        debugTrace("OpenAICompat.sendPost: got status=${resp.status}")
        if (resp.status != 200) {
            let errBody = StringReader(resp.body).readToEnd()
            debugTrace("OpenAICompat.sendPost: error body_size=${errBody.size}, body=${errBody}, closing client")
            client.close()
            let errObj = JsonObject()
            errObj.put("error", JsonString("HTTP ${resp.status}: ${errBody}"))
            return errObj.toJsonString()
        }
        let result = StringReader(resp.body).readToEnd()
        debugTrace("OpenAICompat.sendPost: response body_size=${result.size}, closing client")
        client.close()
        debugTrace("OpenAICompat.sendPost: done")
        result
    }

    private func streamPost(url: String, body: String, onEvent: (StreamEvent) -> Unit): ChatResponse {
        debugTrace("OpenAICompat.streamPost: build client url=${url}, body_size=${body.size}")
        let client = if (url.startsWith("https://")) {
            let tlsConfig = TlsClientConfig()
            ClientBuilder()
                .tlsConfig(tlsConfig)
                .readTimeout(Duration.second * (timeoutSec * 3))  // 流式时间更长
                .writeTimeout(Duration.second * timeoutSec)
                .build()
        } else {
            ClientBuilder()
                .readTimeout(Duration.second * (timeoutSec * 3))  // 流式时间更长
                .writeTimeout(Duration.second * timeoutSec)
                .build()
        }
        let req = HttpRequestBuilder()
            .post()
            .url(url)
            .header("Content-Type", "application/json")
            .header("Authorization", "Bearer " + apiKey)
            .header("Accept", "text/event-stream")
            .body(body)
            .build()
        let resp = client.send(req)
        debugTrace("OpenAICompat.streamPost: got status=${resp.status}")

        if (resp.status != 200) {
            let errBody = StringReader(resp.body).readToEnd()
            debugTrace("OpenAICompat.streamPost: error body_size=${errBody.size}, body=${errBody}, closing client")
            client.close()
            let errMsg = "HTTP ${resp.status}: ${errBody}"
            onEvent(StreamEvent.Error(errMsg))
            return ChatResponse(errBody, "error: ${errMsg}", Usage.empty())
        }

        let parser = SseParser()
        let buf = Array<UInt8>(4096, repeat: 0)
        var finalUsage = Usage.empty()
        var contentAccum = ""
        var stopReason = ""
        var toolCallAccum = ArrayList<ToolCall>()
        // Per-block tracking for parallel tool calls
        var toolCallState = ArrayList<(String, String, String)>()  // (id, name, partial_json)

        var len = resp.body.read(buf)
        while (len > 0) {
            for (i in 0..len) { parser.feedByte(buf[i]) }

            var evt = parser.tryGetEvent()
            while (true) {
                match (evt) {
                    case Some(e) =>
                        if (e.data == "[DONE]") {
                            onEvent(StreamEvent.Done(finalUsage))
                            // accumulate any pending tool calls
                            for (ti in 0..toolCallState.size) {
                                let (tcId, tcName, tcJson) = toolCallState[ti]
                                if (tcId.size > 0) {
                                    toolCallAccum.add(ToolCall(tcId, tcName, tcJson))
                                }
                            }
                            client.close()
                            var resultDone = ChatResponse(contentAccum, if (stopReason.size > 0) { stopReason } else { "stop" }, finalUsage)
                            for (ti in 0..toolCallAccum.size) { resultDone.toolCalls.add(toolCallAccum[ti]) }
                            return resultDone
                        }
                        if (e.data.size > 0) {
                            let (contentDelta, finishReason, usage) = processOpenAIChunk(e.data, toolCallState, toolCallAccum, onEvent)
                            if (contentDelta.size > 0) {
                                contentAccum += contentDelta
                            }
                            if (finishReason.size > 0) {
                                stopReason = finishReason
                            }
                            if (usage.inputTokens > 0 || usage.outputTokens > 0) {
                                finalUsage = usage
                            }
                        }
                        evt = parser.tryGetEvent()
                    case None => break
                }
            }
            len = resp.body.read(buf)
        }
        client.close()
        onEvent(StreamEvent.Done(finalUsage))
        var result = ChatResponse(contentAccum, if (stopReason.size > 0) { stopReason } else { "stop" }, finalUsage)
        for (ti in 0..toolCallAccum.size) { result.toolCalls.add(toolCallAccum[ti]) }
        result
    }

    /// Process a single OpenAI SSE chunk
    private func processOpenAIChunk(dataJson: String,
                                    toolCallState: ArrayList<(String, String, String)>,
                                    toolCallAccum: ArrayList<ToolCall>,
                                    onEvent: (StreamEvent) -> Unit): (String, String, Usage) {
        try {
            let jv = JsonValue.fromStr(dataJson)
            let root = jv.asObject()
            let usage = parseUsage(root)
            var contentDelta = ""
            var finishReason = ""

            match (root.get("choices")) {
                case Some(cArr) =>
                    let arr = cArr.asArray()
                    if (arr.size() > 0) {
                        match (arr.get(0)) {
                            case Some(firstJv) =>
                                let first = firstJv.asObject()

                                // Text delta
                                match (first.get("delta")) {
                                    case Some(dJv) =>
                                        let d = dJv.asObject()
                                        let content = jsonGetString(d, "content", "")
                                        if (content.size > 0) {
                                            contentDelta += content
                                            onEvent(StreamEvent.Chunk(content))
                                        }
                                        // Tool call delta
                                        match (d.get("tool_calls")) {
                                            case Some(tcJv) =>
                                                let tcArr = tcJv.asArray()
                                                for (ti in 0..tcArr.size()) {
                                                    match (tcArr.get(ti)) {
                                                        case Some(tcJv2) =>
                                                            let tc = tcJv2.asObject()
                                                            let tcIdx = jsonGetInt(tc, "index", -1)
                                                            let tcId = jsonGetString(tc, "id", "")
                                                            match (tc.get("function")) {
                                                                case Some(funcJv) =>
                                                                    let f = funcJv.asObject()
                                                                    let tcName = jsonGetString(f, "name", "")
                                                                    let tcArgs = jsonGetString(f, "arguments", "")

                                                                    // Ensure state slot exists
                                                                    while (toolCallState.size <= tcIdx) {
                                                                        toolCallState.add(("", "", ""))
                                                                    }

                                                                    var (prevId, prevName, prevJson) = toolCallState[tcIdx]

                                                                    if (tcId.size > 0 && prevId.size == 0) {
                                                                        // New tool call starting
                                                                        onEvent(StreamEvent.ToolCallStart(tcId))
                                                                    }
                                                                    if (tcName.size > 0 && prevName.size == 0) {
                                                                        prevName = tcName
                                                                    }
                                                                    if (tcArgs.size > 0) {
                                                                        prevJson += tcArgs
                                                                        onEvent(StreamEvent.ToolCallDelta(tcArgs))
                                                                    }

                                                                    toolCallState[tcIdx] = (tcId, prevName, prevJson)
                                                                case None => ()
                                                            }
                                                        case None => ()
                                                    }
                                                }
                                            case None => ()
                                        }
                                    case None => ()
                                }

                                // Finish reason
                                let fr = jsonGetString(first, "finish_reason", "")
                                if (fr.size > 0) {
                                    finishReason = fr
                                }
                                if (fr == "tool_calls" || fr == "function_call") {
                                    // Drain pending tool calls
                                    for (ti in 0..toolCallState.size) {
                                        let (tcId, tcName, tcJson) = toolCallState[ti]
                                        if (tcId.size > 0) {
                                            toolCallAccum.add(ToolCall(tcId, tcName, tcJson))
                                            onEvent(StreamEvent.ToolCallEnd(tcId, tcName))
                                        }
                                    }
                                    toolCallState.clear()
                                }
                            case None => ()
                        }
                    }
                case None => ()
            }
            (contentDelta, finishReason, usage)
        } catch (_: Exception) {
            ("", "", Usage.empty())
        }
    }

    // ── 请求构造 ──

    private func buildRequestBody(req: ChatRequest, stream: Bool): String {
        let obj = JsonObject()
        obj.put("model", JsonString(if (req.model.size > 0) { req.model } else { model }))
        obj.put("stream", JsonBool(stream))

        // messages
        let msgs = JsonArray()
        // system prompt
        match (req.systemPrompt) {
            case Some(sp) =>
                let sysObj = JsonObject()
                sysObj.put("role", JsonString("system"))
                sysObj.put("content", JsonString(sp))
                msgs.add(sysObj)
            case None => ()
        }
        // conversation messages
        for (i in 0..req.messages.size) {
            let m = req.messages[i]
            let mObj = JsonObject()
            mObj.put("role", JsonString(roleToString(m.role)))
            mObj.put("content", JsonString(m.content))
            msgs.add(mObj)
        }
        obj.put("messages", msgs)

        // temperature
        match (req.temperature) {
            case Some(t) => obj.put("temperature", JsonFloat(t))
            case None => ()
        }

        // max_tokens
        match (req.maxTokens) {
            case Some(mt) => obj.put("max_tokens", JsonInt(mt))
            case None => ()
        }

        // tools
        match (req.tools) {
            case Some(tools) =>
                let toolsArr = JsonArray()
                for (i in 0..tools.size) {
                    let t = tools[i]
                    let tObj = JsonObject()
                    tObj.put("type", JsonString("function"))
                    let funcObj = JsonObject()
                    funcObj.put("name", JsonString(t.name))
                    funcObj.put("description", JsonString(t.description))
                    try {
                        funcObj.put("parameters", JsonValue.fromStr(t.parameters))
                    } catch (_: Exception) {
                        funcObj.put("parameters", JsonObject())
                    }
                    tObj.put("function", funcObj)
                    toolsArr.add(tObj)
                }
                obj.put("tools", toolsArr)
            case None => ()
        }

        // tool_choice
        match (req.toolChoice) {
            case Some(tc) =>
                match (tc) {
                    case ToolChoice.Auto => obj.put("tool_choice", JsonString("auto"))
                    case ToolChoice.Required => obj.put("tool_choice", JsonString("required"))
                    case ToolChoice.NoTool => obj.put("tool_choice", JsonString("none"))
                }
            case None => ()
        }

        // response_format
        match (req.responseFormat) {
            case Some(rf) =>
                match (rf) {
                    case ResponseFormat.JsonObject =>
                        let rfObj = JsonObject()
                        rfObj.put("type", JsonString("json_object"))
                        obj.put("response_format", rfObj)
                    case ResponseFormat.JsonSchema(name, schema) =>
                        let rfObj = JsonObject()
                        rfObj.put("type", JsonString("json_schema"))
                        let jsObj = JsonObject()
                        jsObj.put("name", JsonString(name))
                        jsObj.put("strict", JsonBool(true))
                        try {
                            jsObj.put("schema", JsonValue.fromStr(schema))
                        } catch (_: Exception) {
                            jsObj.put("schema", JsonObject())
                        }
                        rfObj.put("json_schema", jsObj)
                        obj.put("response_format", rfObj)
                }
            case None => ()
        }

        obj.toJsonString()
    }

    // ── 响应解析 ──

    private func parseChatResponse(jsonText: String): ChatResponse {
        try {
            let jv = JsonValue.fromStr(jsonText)
            let root = jv.asObject()
            match (root.get("choices")) {
                case Some(cArr) =>
                    let arr = cArr.asArray()
                    if (arr.size() > 0) {
                        match (arr.get(0)) {
                            case Some(firstJv) =>
                                let first = firstJv.asObject()
                                match (first.get("message")) {
                                    case Some(msgJv) =>
                                        let m = msgJv.asObject()
                                        let content = jsonGetString(m, "content", "")
                                        let fr = jsonGetString(first, "finish_reason", "stop")
                                        let usage = parseUsage(root)
                                        var resp = ChatResponse(content, fr, usage)
                                        // tool calls
                                        match (m.get("tool_calls")) {
                                            case Some(tcJv) =>
                                                let tcList = tcJv.asArray()
                                                for (ti in 0..tcList.size()) {
                                                    match (tcList.get(ti)) {
                                                        case Some(tcJv2) =>
                                                            let tc = tcJv2.asObject()
                                                            let tcId = jsonGetString(tc, "id", "")
                                                            match (tc.get("function")) {
                                                                case Some(funcJv) =>
                                                                    let f = funcJv.asObject()
                                                                    let tcName = jsonGetString(f, "name", "")
                                                                    let tcArgs = jsonGetString(f, "arguments", "")
                                                                    resp.toolCalls.add(ToolCall(tcId, tcName, tcArgs))
                                                                case None => ()
                                                            }
                                                        case None => ()
                                                    }
                                                }
                                            case None => ()
                                        }
                                        resp
                                    case None => ChatResponse.empty()
                                }
                            case None => ChatResponse.empty()
                        }
                    } else {
                        ChatResponse.empty()
                    }
                case None =>
                    match (root.get("error")) {
                        case Some(errJv) =>
                            ChatResponse(jsonText, "error: ${errorToString(errJv)}", Usage.empty())
                        case None => ChatResponse.empty()
                    }
            }
        } catch (_: Exception) {
            ChatResponse.empty()
        }
    }

    private func shouldFallbackToJsonObject(req: ChatRequest, resp: ChatResponse): Bool {
        match (req.responseFormat) {
            case Some(rf) =>
                match (rf) {
                    case ResponseFormat.JsonSchema(_, _) =>
                        resp.finishReason.contains("response_format type is unavailable")
                    case _ => false
                }
            case None => false
        }
    }

    private func errorToString(errJv: JsonValue): String {
        try {
            match (errJv.kind()) {
                case JsString => errJv.asString().getValue()
                case JsObject =>
                    let obj = errJv.asObject()
                    let message = jsonGetString(obj, "message", "")
                    if (message.size > 0) { message } else { errJv.toJsonString() }
                case _ => errJv.toJsonString()
            }
        } catch (_: Exception) {
            "unknown"
        }
    }

    private func parseUsage(root: JsonObject): Usage {
        match (root.get("usage")) {
            case Some(uObj) =>
                let u = uObj.asObject()
                let input = jsonGetInt(u, "prompt_tokens", 0)
                let output = jsonGetInt(u, "completion_tokens", 0)
                Usage(input, output)
            case None => Usage.empty()
        }
    }

    private func roleToString(role: MessageRole): String {
        match (role) {
            case MessageRole.System => "system"
            case MessageRole.User => "user"
            case MessageRole.Assistant => "assistant"
            case MessageRole.Tool => "tool"
        }
    }
}

/// 创建默认的 OpenAI Provider 实例
public func createOpenAICompatProvider(apiKey: String, model: String): OpenAICompatProvider {
    OpenAICompatProvider("https://api.openai.com/v1", apiKey, model, 60)
}
