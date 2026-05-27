package termhelper.adapters

import termhelper.types.*
import termhelper.infra.*
import std.collection.ArrayList
import stdx.net.http.*
import stdx.net.tls.*
import stdx.encoding.json.*
import std.io.*
import std.time.*

/// OpenAI Compatible Provider — /v1/chat/completions 协议
/// 兼容 OpenAI / DeepSeek / Moonshot 等兼容服务
public class OpenAICompatProvider {
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

    public func chat(req: ChatRequest): ChatResponse {
        // json_object mode: skip json_schema attempt
        if (req.structuredOutputMode == "json_object") {
            req.responseFormat = Some(ResponseFormat.JsonObject)
            return chatCollect(req)
        }
        let parsed = chatCollect(req)
        if (shouldFallbackToJsonObject(req, parsed)) {
            debugTrace("OpenAICompat.chat: json_schema unavailable, retrying with json_object")
            req.responseFormat = Some(ResponseFormat.JsonObject)
            match (req.fallbackSystemPrompt) {
                case Some(p) => req.systemPrompt = Some(p)
                case None => ()
            }
            return chatCollect(req)
        }
        parsed
    }

    public func chatStream(req: ChatRequest, onEvent: (StreamEvent) -> Unit): ChatResponse {
        let body = buildRequestBody(req, true)
        let url = "${baseUrl}/chat/completions"
        streamPost(url, body, onEvent)
    }

    public func chatWithTools(req: ChatRequest, onEvent: (StreamEvent) -> Unit): ChatResponse {
        let body = buildRequestBody(req, true)
        let url = "${baseUrl}/chat/completions"
        streamPost(url, body, onEvent)
    }

    private func chatCollect(req: ChatRequest): ChatResponse {
        let body = buildRequestBody(req, true)
        let url = "${baseUrl}/chat/completions"
        streamPost(url, body, { _ => () })
    }

    private func sendPost(url: String, body: String): String {
        debugTrace("OpenAICompat.sendPost: url=${url}, body_size=${body.size}")
        let client = buildClient(readTimeoutSec)
        let req = HttpRequestBuilder()
            .post()
            .url(url)
            .header("Content-Type", "application/json")
            .header("Authorization", "Bearer " + apiKey)
            .body(body)
            .build()
        debugTrace("OpenAICompat.sendPost: sending")
        let resp = client.send(req)
        debugTrace("OpenAICompat.sendPost: status=${resp.status}")
        if (resp.status != 200) {
            let errBody = StringReader(resp.body).readToEnd()
            client.close()
            let errObj = JsonObject()
            errObj.put("error", JsonString("HTTP ${resp.status}: ${errBody}"))
            return errObj.toJsonString()
        }
        let result = StringReader(resp.body).readToEnd()
        client.close()
        debugTrace("OpenAICompat.sendPost: done")
        result
    }

    private func streamPost(url: String, body: String, onEvent: (StreamEvent) -> Unit): ChatResponse {
        debugTrace("OpenAICompat.streamPost: url=${url}, body_size=${body.size}")
        // 流式读超时放宽到 idleTimeoutSec（两次 chunk 的最大间隔）
        let client = buildClient(if (idleTimeoutSec > readTimeoutSec) { idleTimeoutSec } else { readTimeoutSec * 3 })

        let req = HttpRequestBuilder()
            .post()
            .url(url)
            .header("Content-Type", "application/json")
            .header("Authorization", "Bearer " + apiKey)
            .header("Accept", "text/event-stream")
            .body(body)
            .build()
        let resp = client.send(req)
        debugTrace("OpenAICompat.streamPost: status=${resp.status}")

        if (resp.status != 200) {
            let errBody = StringReader(resp.body).readToEnd()
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
        var toolCallState = ArrayList<(String, String, String)>()

        var len = resp.body.read(buf)
        while (len > 0) {
            for (i in 0..len) { parser.feedByte(buf[i]) }

            var evt = parser.tryGetEvent()
            while (true) {
                match (evt) {
                    case Some(e) =>
                        if (e.data == "[DONE]") {
                            onEvent(StreamEvent.Done(finalUsage))
                            for (ti in 0..toolCallState.size) {
                                let (tcId, tcName, tcJson) = toolCallState[ti]
                                if (tcId.size > 0) { toolCallAccum.add(ToolCall(tcId, tcName, tcJson)) }
                            }
                            client.close()
                            var resultDone = ChatResponse(contentAccum, if (stopReason.size > 0) { stopReason } else { "stop" }, finalUsage)
                            for (ti in 0..toolCallAccum.size) { resultDone.toolCalls.add(toolCallAccum[ti]) }
                            return resultDone
                        }
                        if (e.data.size > 0) {
                            let (delta, fr, usage) = processOpenAIChunk(e.data, toolCallState, toolCallAccum, onEvent)
                            if (delta.size > 0) { contentAccum += delta }
                            if (fr.size > 0) { stopReason = fr }
                            if (usage.inputTokens > 0 || usage.outputTokens > 0) { finalUsage = usage }
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
                                match (first.get("delta")) {
                                    case Some(dJv) =>
                                        let d = dJv.asObject()
                                        let content = jsonGetString(d, "content", "")
                                        if (content.size > 0) {
                                            contentDelta += content
                                            onEvent(StreamEvent.Chunk(content))
                                        }
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
                                                                    while (toolCallState.size <= tcIdx) {
                                                                        toolCallState.add(("", "", ""))
                                                                    }
                                                                    var (prevId, prevName, prevJson) = toolCallState[tcIdx]
                                                                    if (tcId.size > 0 && prevId.size == 0) {
                                                                        onEvent(StreamEvent.ToolCallStart(tcId))
                                                                    }
                                                                    if (tcName.size > 0 && prevName.size == 0) { prevName = tcName }
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
                                let fr = jsonGetString(first, "finish_reason", "")
                                if (fr.size > 0) { finishReason = fr }
                                if (fr == "tool_calls" || fr == "function_call") {
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
        } catch (_: Exception) { ("", "", Usage.empty()) }
    }

    private func buildRequestBody(req: ChatRequest, stream: Bool): String {
        let obj = JsonObject()
        obj.put("model", JsonString(if (req.model.size > 0) { req.model } else { model }))
        obj.put("stream", JsonBool(stream))

        let msgs = JsonArray()
        match (req.systemPrompt) {
            case Some(sp) =>
                let sysObj = JsonObject()
                sysObj.put("role", JsonString("system"))
                sysObj.put("content", JsonString(sp))
                msgs.add(sysObj)
            case None => ()
        }
        for (i in 0..req.messages.size) {
            let m = req.messages[i]
            let mObj = JsonObject()
            mObj.put("role", JsonString(roleToString(m.role)))
            mObj.put("content", JsonString(m.content))
            msgs.add(mObj)
        }
        obj.put("messages", msgs)

        match (req.temperature) {
            case Some(t) => obj.put("temperature", JsonFloat(t))
            case None => ()
        }
        match (req.maxTokens) {
            case Some(mt) => obj.put("max_tokens", JsonInt(mt))
            case None => ()
        }

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
                    try { funcObj.put("parameters", JsonValue.fromStr(t.parameters)) } catch (_: Exception) { funcObj.put("parameters", JsonObject()) }
                    tObj.put("function", funcObj)
                    toolsArr.add(tObj)
                }
                obj.put("tools", toolsArr)
            case None => ()
        }

        match (req.toolChoice) {
            case Some(tc) =>
                match (tc) {
                    case ToolChoice.Auto => obj.put("tool_choice", JsonString("auto"))
                    case ToolChoice.Required => obj.put("tool_choice", JsonString("required"))
                    case ToolChoice.NoTool => obj.put("tool_choice", JsonString("none"))
                }
            case None => ()
        }

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
                        try { jsObj.put("schema", JsonValue.fromStr(schema)) } catch (_: Exception) { jsObj.put("schema", JsonObject()) }
                        rfObj.put("json_schema", jsObj)
                        obj.put("response_format", rfObj)
                }
            case None => ()
        }

        obj.toJsonString()
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

    private func roleToString(role: MessageRole): String {
        match (role) {
            case MessageRole.System => "system"
            case MessageRole.User => "user"
            case MessageRole.Assistant => "assistant"
            case MessageRole.Tool => "tool"
        }
    }
}

public func createOpenAICompatProvider(apiKey: String, model: String): OpenAICompatProvider {
    OpenAICompatProvider("https://api.openai.com/v1", apiKey, model, 10, 60, 30)
}
