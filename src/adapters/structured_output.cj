package termhelper.adapters

import termhelper.types.*
import std.collection.*
import stdx.encoding.json.*

// ═══════════════════════════════════════════════════════════════
// Structured Output 适配层
// — JSON Schema 构造工具
// — 各 Provider 的 response_format 注入
// — JSON 响应解析与 Schema 校验
// ═══════════════════════════════════════════════════════════════

// ── JSON Schema 构造 ──

/// 构造一个简单的 JSON Schema（返回 JSON 字符串）
/// properties: [(name, type, description)]
/// type: "string" | "number" | "integer" | "boolean" | "array" | "object"
public func makeJsonSchema(title: String, properties: ArrayList<(String, String, String)>, required: ArrayList<String>): String {
    let obj = JsonObject()
    obj.put("type", JsonString("object"))

    let propsObj = JsonObject()
    for (i in 0..properties.size) {
        let (name, typ, desc) = properties[i]
        let propObj = JsonObject()
        propObj.put("type", JsonString(typ))
        if (desc.size > 0) {
            propObj.put("description", JsonString(desc))
        }
        propsObj.put(name, propObj)
    }
    obj.put("properties", propsObj)

    if (required.size > 0) {
        let reqArr = JsonArray()
        for (i in 0..required.size) {
            reqArr.add(JsonString(required[i]))
        }
        obj.put("required", reqArr)
    }

    if (title.size > 0) {
        obj.put("title", JsonString(title))
    }
    obj.put("additionalProperties", JsonBool(false))
    obj.toJsonString()
}

/// 为 OpenAI / Compatible Provider 设置 response_format
public func setOpenAIResponseFormat(req: ChatRequest, schemaTitle: String, schemaJson: String): Unit {
    req.responseFormat = Some(ResponseFormat.JsonSchema(schemaTitle, schemaJson))
}

/// 为 OpenAI / Compatible Provider 设置 json_object response_format
public func setOpenAIJsonObjectResponseFormat(req: ChatRequest): Unit {
    req.responseFormat = Some(ResponseFormat.JsonObject)
}

/// 为 Anthropic Provider 设置 Structured Output（使用 json tool）
/// Anthropic 不支持原生的 response_format，需要通过 tool_use 实现
public func setAnthropicStructuredOutput(req: ChatRequest, schemaTitle: String, schemaJson: String): Unit {
    // 创建一个 json tool，input_schema 为 JSON Schema
    let tool = ToolDefinition(schemaTitle, "Generate a JSON response matching the schema", schemaJson)
    var tools = ArrayList<ToolDefinition>()
    tools.add(tool)
    req.tools = Some(tools)
    req.toolChoice = Some(ToolChoice.Required)
}

/// 为 Google Provider 设置 response_format
public func setGoogleResponseFormat(req: ChatRequest, schemaTitle: String, schemaJson: String): Unit {
    req.responseFormat = Some(ResponseFormat.JsonSchema(schemaTitle, schemaJson))
}

// ── 响应解析与校验 ──

/// 从响应中提取 JSON 对象（解析失败返回空 JsonObject）
public func extractJsonFromResponse(response: ChatResponse): JsonObject {
    try {
        let content = response.content.trimAscii()

        // 尝试直接解析
        let jv = JsonValue.fromStr(content)
        jv.asObject()
    } catch (_: Exception) {
        // 尝试提取 ```json ... ``` 代码块
        let jsonBlock = extractJsonBlock(response.content)
        if (jsonBlock.size > 0) {
            try {
                let jv = JsonValue.fromStr(jsonBlock)
                jv.asObject()
            } catch (_: Exception) {
                JsonObject()
            }
        } else {
            JsonObject()
        }
    }
}

/// 从文本中提取 ```json ... ``` 代码块
private func extractJsonBlock(text: String): String {
    let startMarker = "```json"
    let bytes = text.toArray()
    var startIdx: Int64 = -1
    var i: Int64 = 0

    // 查找 ```json
    while (i <= bytes.size - 7) {
        var found = true
        for (j in 0..7) {
            if (bytes[i + j] != startMarker.toArray()[j]) {
                found = false
                break
            }
        }
        if (found) {
            startIdx = i + 7
            break
        }
        i += 1
    }

    if (startIdx < 0) {
        return ""
    }

    // 跳过 startMarker 后的换行符
    var pos = startIdx
    while (pos < bytes.size && (bytes[pos] == b'\n' || bytes[pos] == b'\r')) {
        pos += 1
    }

    // 查找结尾 ```
    var endIdx: Int64 = -1
    var j = pos
    while (j <= bytes.size - 3) {
        if (bytes[j] == b'`' && bytes[j + 1] == b'`' && bytes[j + 2] == b'`') {
            endIdx = j
            break
        }
        j += 1
    }

    if (endIdx < 0) {
        return ""
    }

    text[pos..endIdx].trimAscii()
}

/// 校验 JSON 对象是否包含必需字段
public func validateRequiredFields(obj: JsonObject, requiredFields: ArrayList<String>): Bool {
    for (i in 0..requiredFields.size) {
        match (obj.get(requiredFields[i])) {
            case Some(_) => ()
            case None => return false
        }
    }
    true
}

/// 根据 JSON Schema 字符串校验 JSON 对象的基本结构
public func validateJsonSchema(obj: JsonObject, schemaJson: String): Bool {
    try {
        let schema = JsonValue.fromStr(schemaJson).asObject()
        match (schema.get("required")) {
            case Some(reqJv) =>
                let reqArr = reqJv.asArray()
                var fields = ArrayList<String>()
                for (i in 0..reqArr.size()) {
                    match (reqArr.get(i)) {
                        case Some(fieldJv) => match (fieldJv.kind()) {
                            case JsString => fields.add(fieldJv.asString().getValue())
                            case _ => ()
                        }
                        case None => ()
                    }
                }
                validateRequiredFields(obj, fields)
            case None => true // no required fields → always valid
        }
    } catch (_: Exception) {
        false
    }
}
