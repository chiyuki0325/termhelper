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
// Google Gemini Provider — /v1beta/models/{model}:generateContent 协议
// 参考: references/ai/packages/google/src/google-language-model.ts
// ═══════════════════════════════════════════════════════════════

/// Google Gemini Provider
public class GoogleProvider {
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
        let body = buildRequestBody(req)
        let modelPath = if (req.model.size > 0) { req.model } else { model }
        let url = "${baseUrl}/models/${modelPath}:generateContent"
        let respText = sendPost(url, body)
        parseChatResponse(respText)
    }

    /// 流式对话
    public func chatStream(req: ChatRequest, onEvent: (StreamEvent) -> Unit): ChatResponse {
        let body = buildRequestBody(req)
        let modelPath = if (req.model.size > 0) { req.model } else { model }
        let url = "${baseUrl}/models/${modelPath}:streamGenerateContent?alt=sse"
        streamPost(url, body, onEvent)
    }

    /// 流式 tool-calling 对话
    public func chatWithTools(req: ChatRequest, onEvent: (StreamEvent) -> Unit): ChatResponse {
        let body = buildRequestBody(req)
        let modelPath = if (req.model.size > 0) { req.model } else { model }
        let url = "${baseUrl}/models/${modelPath}:streamGenerateContent?alt=sse"
        streamPost(url, body, onEvent)
    }

    // ── HTTP ──

    private func sendPost(url: String, body: String): String {
        debugTrace("Google.sendPost: build client url=${url}, body_size=${body.size}")
        let client = buildClient(readTimeoutSec)
        let req = HttpRequestBuilder()
            .post()
            .url(url)
            .header("Content-Type", "application/json")
            .header("x-goog-api-key", apiKey)
            .body(body)
            .build()
        debugTrace("Google.sendPost: sending request")
        let resp = client.send(req)
        debugTrace("Google.sendPost: got status=${resp.status}")
        if (resp.status != 200) {
            let errBody = StringReader(resp.body).readToEnd()
            debugTrace("Google.sendPost: error body_size=${errBody.size}, closing client")
            client.close()
            let errObj = JsonObject()
            errObj.put("error", JsonString("HTTP ${resp.status}: ${errBody}"))
            return errObj.toJsonString()
        }
        let result = StringReader(resp.body).readToEnd()
        debugTrace("Google.sendPost: response body_size=${result.size}, closing client")
        client.close()
        debugTrace("Google.sendPost: done")
        result
    }

    private func streamPost(url: String, body: String, onEvent: (StreamEvent) -> Unit): ChatResponse {
        debugTrace("Google.streamPost: build client url=${url}, body_size=${body.size}")
        let streamTimeout = if (idleTimeoutSec > readTimeoutSec) { idleTimeoutSec } else { readTimeoutSec * 3 }
        let client = buildClient(streamTimeout)
        let req = HttpRequestBuilder()
            .post()
            .url(url)
            .header("Content-Type", "application/json")
            .header("x-goog-api-key", apiKey)
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
        var finishReason = ""
        // Track functionCalls by (id, name, accumulated_args_json)
        var activeFnCalls = ArrayList<(String, String, String)>()

        var len = resp.body.read(buf)
        while (len > 0) {
            for (i in 0..len) { parser.feedByte(buf[i]) }

            var evt = parser.tryGetEvent()
            while (true) {
                match (evt) {
                    case Some(e) =>
                        if (e.data.size > 0) {
                            let (deltaText, fr, usage) = parseStreamChunk(e.data, activeFnCalls, onEvent)
                            if (deltaText.size > 0) {
                                contentAccum += deltaText
                                onEvent(StreamEvent.Chunk(deltaText))
                            }
                            if (usage.inputTokens > 0 || usage.outputTokens > 0) {
                                finalUsage = usage
                            }
                            if (fr.size > 0) { finishReason = fr }
                        }
                    case None => break
                }
                evt = parser.tryGetEvent()
            }
            len = resp.body.read(buf)
        }

        // Finalize any pending function calls with accumulated args
        var toolCalls = ArrayList<ToolCall>()
        for (fi in 0..activeFnCalls.size) {
            let (fnId, fnName, accumulatedArgs) = activeFnCalls[fi]
            onEvent(StreamEvent.ToolCallEnd(fnId, fnName, accumulatedArgs))
            toolCalls.add(ToolCall(fnId, fnName, accumulatedArgs))
        }

        client.close()
        onEvent(StreamEvent.Done(finalUsage))
        var resp2 = ChatResponse(contentAccum, finishReason, finalUsage)
        for (fi in 0..toolCalls.size) { resp2.toolCalls.add(toolCalls[fi]) }
        resp2
    }

    /// Parse one SSE data chunk from Google stream
    /// activeFnCalls: (id, name, accumulated_args_json) — mutated in place
    private func parseStreamChunk(dataJson: String, activeFnCalls: ArrayList<(String, String, String)>,
                                   onEvent: (StreamEvent) -> Unit): (String, String, Usage) {
        try {
            let jv = JsonValue.fromStr(dataJson)
            let root = jv.asObject()

            var textDelta = ""
            var finishReason = ""

            match (root.get("candidates")) {
                case Some(candsJv) =>
                    let arr = candsJv.asArray()
                    if (arr.size() > 0) {
                        match (arr.get(0)) {
                            case Some(candJv) =>
                                let cand = candJv.asObject()
                                finishReason = jsonGetString(cand, "finishReason", "")
                                match (cand.get("content")) {
                                    case Some(contentJv) =>
                                        let content = contentJv.asObject()
                                        match (content.get("parts")) {
                                            case Some(partsJv) =>
                                                let parts = partsJv.asArray()
                                                for (i in 0..parts.size()) {
                                                    match (parts.get(i)) {
                                                        case Some(partJv) =>
                                                            let part = partJv.asObject()
                                                            // Text
                                                            let partText = jsonGetString(part, "text", "")
                                                            if (partText.size > 0) {
                                                                if (jsonGetBool(part, "thought", false)) {
                                                                    onEvent(StreamEvent.ReasoningChunk(partText))
                                                                } else {
                                                                    textDelta += partText
                                                                }
                                                            }
                                                            // Function call
                                                            match (part.get("functionCall")) {
                                                                case Some(fcJv) =>
                                                                    let fc = fcJv.asObject()
                                                                    let fnName = jsonGetString(fc, "name", "")
                                                                    let fnId = jsonGetString(fc, "id", "")
                                                                    if (fnName.size > 0) {
                                                                        // Find or create tracking slot
                                                                        var slotIdx: Int64 = -1
                                                                        for (ai in 0..activeFnCalls.size) {
                                                                            let (aid, aname, _) = activeFnCalls[ai]
                                                                            if (aid == fnId || (aid.size == 0 && fnId.size == 0 && aname == fnName)) {
                                                                                slotIdx = ai
                                                                                break
                                                                            }
                                                                        }
                                                                        if (slotIdx < 0) {
                                                                            activeFnCalls.add((fnId, fnName, ""))
                                                                            slotIdx = activeFnCalls.size - 1
                                                                            onEvent(StreamEvent.ToolCallStart(if (fnId.size > 0) { fnId } else { fnName }))
                                                                        }

                                                                        // Handle args (full object) or partialArgs (Gemini 2.5+ incremental array)
                                                                        match (fc.get("args")) {
                                                                            case Some(argsJv) =>
                                                                                let argsJson = argsJv.toJsonString()
                                                                                let (aid, aname, prevJson) = activeFnCalls[slotIdx]
                                                                                activeFnCalls[slotIdx] = (aid, aname, prevJson + argsJson)
                                                                                onEvent(StreamEvent.ToolCallDelta(aid, argsJson))
                                                                            case None => ()
                                                                        }
                                                                        match (fc.get("partialArgs")) {
                                                                            case Some(paJv) =>
                                                                                let paArr = paJv.asArray()
                                                                                for (pai in 0..paArr.size()) {
                                                                                    match (paArr.get(pai)) {
                                                                                        case Some(entryJv) =>
                                                                                            let entryJson = entryJv.toJsonString()
                                                                                            let (aid, aname, prevJson) = activeFnCalls[slotIdx]
                                                                                            activeFnCalls[slotIdx] = (aid, aname, prevJson + entryJson)
                                                                                            onEvent(StreamEvent.ToolCallDelta(aid, entryJson))
                                                                                        case None => ()
                                                                                    }
                                                                                }
                                                                            case None => ()
                                                                        }
                                                                    }
                                                                case None => ()
                                                            }
                                                        case None => ()
                                                    }
                                                }
                                            case None => ()
                                        }
                                    case None => ()
                                }
                            case None => ()
                        }
                    }
                case None => ()
            }

            let usage = match (root.get("usageMetadata")) {
                case Some(uJv) =>
                    let u = uJv.asObject()
                    Usage(jsonGetInt(u, "promptTokenCount", 0), jsonGetInt(u, "candidatesTokenCount", 0))
                case None => Usage.empty()
            }

            (textDelta, finishReason, usage)
        } catch (_: Exception) {
            ("", "", Usage.empty())
        }
    }

    // ── 请求构造 ──

    private func buildRequestBody(req: ChatRequest): String {
        let obj = JsonObject()

        // systemInstruction
        if (req.systemPrompts.size > 0) {
            let sysObj = JsonObject()
            let partsArr = JsonArray()
            for (i in 0..req.systemPrompts.size) {
                let textPart = JsonObject()
                textPart.put("text", JsonString(req.systemPrompts[i]))
                partsArr.add(textPart)
            }
            sysObj.put("parts", partsArr)
            obj.put("systemInstruction", sysObj)
        } else {
            match (req.systemPrompt) {
                case Some(sp) =>
                    let sysObj = JsonObject()
                    let partsArr = JsonArray()
                    let textPart = JsonObject()
                    textPart.put("text", JsonString(sp))
                    partsArr.add(textPart)
                    sysObj.put("parts", partsArr)
                    obj.put("systemInstruction", sysObj)
                case None => ()
            }
        }

        // contents (messages)
        let contents = JsonArray()
        for (i in 0..req.messages.size) {
            let m = req.messages[i]
            let cObj = JsonObject()
            cObj.put("role", JsonString(googleRole(m.role)))
            let partsArr2 = JsonArray()
            let textPart2 = JsonObject()
            textPart2.put("text", JsonString(m.content))
            partsArr2.add(textPart2)
            cObj.put("parts", partsArr2)
            contents.add(cObj)
        }
        obj.put("contents", contents)

        // generationConfig
        let genConfig = JsonObject()
        match (req.temperature) {
            case Some(t) => genConfig.put("temperature", JsonFloat(t))
            case None => ()
        }
        match (req.maxTokens) {
            case Some(mt) => genConfig.put("maxOutputTokens", JsonInt(mt))
            case None => genConfig.put("maxOutputTokens", JsonInt(8192))
        }

        // response_format → Google's response_mime_type + response_schema
        match (req.responseFormat) {
            case Some(rf) =>
                match (rf) {
                    case ResponseFormat.JsonObject =>
                        genConfig.put("responseMimeType", JsonString("application/json"))
                    case ResponseFormat.JsonSchema(name, schema) =>
                        genConfig.put("responseMimeType", JsonString("application/json"))
                        try {
                            genConfig.put("responseSchema", JsonValue.fromStr(schema))
                        } catch (_: Exception) { () }
                }
            case None => ()
        }

        obj.put("generationConfig", genConfig)

        // tools
        match (req.tools) {
            case Some(tools) =>
                let toolsArr = JsonArray()
                let funcDecls = JsonArray()
                for (i in 0..tools.size) {
                    let t = tools[i]
                    let fdObj = JsonObject()
                    fdObj.put("name", JsonString(t.name))
                    fdObj.put("description", JsonString(t.description))
                    try {
                        fdObj.put("parameters", JsonValue.fromStr(t.parameters))
                    } catch (_: Exception) {
                        fdObj.put("parameters", JsonObject())
                    }
                    funcDecls.add(fdObj)
                }
                let funcDeclsWrapper = JsonObject()
                funcDeclsWrapper.put("functionDeclarations", funcDecls)
                toolsArr.add(funcDeclsWrapper)
                obj.put("tools", toolsArr)
            case None => ()
        }

        // toolConfig
        match (req.toolChoice) {
            case Some(tc) =>
                let tcObj = JsonObject()
                let fccObj = JsonObject()
                match (tc) {
                    case ToolChoice.Auto => fccObj.put("mode", JsonString("AUTO"))
                    case ToolChoice.Required => fccObj.put("mode", JsonString("ANY"))
                    case ToolChoice.NoTool => fccObj.put("mode", JsonString("NONE"))
                }
                tcObj.put("functionCallingConfig", fccObj)
                obj.put("toolConfig", tcObj)
            case None => ()
        }

        obj.toJsonString()
    }

    // ── 非流式响应解析 ──

    private func parseChatResponse(jsonText: String): ChatResponse {
        try {
            let jv = JsonValue.fromStr(jsonText)
            let root = jv.asObject()

            var textContent = ""
            var finishReason = ""

            match (root.get("candidates")) {
                case Some(candsJv) =>
                    let arr = candsJv.asArray()
                    if (arr.size() > 0) {
                        match (arr.get(0)) {
                            case Some(candJv) =>
                                let cand = candJv.asObject()
                                finishReason = jsonGetString(cand, "finishReason", "STOP")
                                match (cand.get("content")) {
                                    case Some(contentJv) =>
                                        let content = contentJv.asObject()
                                        match (content.get("parts")) {
                                            case Some(partsJv) =>
                                                let parts = partsJv.asArray()
                                                for (i in 0..parts.size()) {
                                                    match (parts.get(i)) {
                                                        case Some(partJv) =>
                                                            let part = partJv.asObject()
                                                            // Text
                                                            let partText = jsonGetString(part, "text", "")
                                                            if (partText.size > 0) {
                                                                textContent += partText
                                                            }
                                                        case None => ()
                                                    }
                                                }
                                            case None => ()
                                        }
                                    case None => ()
                                }
                            case None => ()
                        }
                    }
                case None => ()
            }

            let usage = parseUsage(root)
            var resp = ChatResponse(textContent, finishReason, usage)

            // Extract functionCall parts
            match (root.get("candidates")) {
                case Some(candsJv) =>
                    let arr = candsJv.asArray()
                    if (arr.size() > 0) {
                        match (arr.get(0)) {
                            case Some(candJv) =>
                                let cand = candJv.asObject()
                                match (cand.get("content")) {
                                    case Some(contentJv) =>
                                        let content = contentJv.asObject()
                                        match (content.get("parts")) {
                                            case Some(partsJv) =>
                                                let parts = partsJv.asArray()
                                                for (i in 0..parts.size()) {
                                                    match (parts.get(i)) {
                                                        case Some(partJv) =>
                                                            let part = partJv.asObject()
                                                            match (part.get("functionCall")) {
                                                                case Some(fcJv) =>
                                                                    let fc = fcJv.asObject()
                                                                    let fnName = jsonGetString(fc, "name", "")
                                                                    let fnId = jsonGetString(fc, "id", "")
                                                                    match (fc.get("args")) {
                                                                        case Some(argsJv) =>
                                                                            resp.toolCalls.add(ToolCall(fnId, fnName, argsJv.toJsonString()))
                                                                        case None => ()
                                                                    }
                                                                case None => ()
                                                            }
                                                        case None => ()
                                                    }
                                                }
                                            case None => ()
                                        }
                                    case None => ()
                                }
                            case None => ()
                        }
                    }
                case None => ()
            }

            resp
        } catch (_: Exception) {
            ChatResponse.empty()
        }
    }

    private func parseUsage(root: JsonObject): Usage {
        match (root.get("usageMetadata")) {
            case Some(uJv) =>
                let u = uJv.asObject()
                let input = jsonGetInt(u, "promptTokenCount", 0)
                let output = jsonGetInt(u, "candidatesTokenCount", 0)
                Usage(input, output)
            case None => Usage.empty()
        }
    }

    private func googleRole(role: MessageRole): String {
        match (role) {
            case MessageRole.User => "user"
            case MessageRole.Assistant => "model"
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

/// Create a default Google provider instance
public func createGoogleProvider(apiKey: String, model: String): GoogleProvider {
    GoogleProvider("https://generativelanguage.googleapis.com/v1beta", apiKey, model, 10, 60, 30)
}
