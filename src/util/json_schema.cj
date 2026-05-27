package termhelper.util

import termhelper.types.*
import termhelper.infra.debugTrace
import naivejson.schema.*
import naivejson.schema.model.*
import naivejson.schema.render.*
import std.collection.*
import stdx.encoding.json.*
import stdx.serialization.serialization.*

// ═══════════════════════════════════════════════════════════════
// LLM 结构化响应：Schema 生成 + 序列化/反序列化
// 使用 naivejson 的 SchemaBuilder + @JsonAdapter 自动生成的 schema
// ═══════════════════════════════════════════════════════════════

/// 生成 LLMResponse 的完整 JSON Schema（用于 Structured Output）
public func llmResponseSchema(): String {
    let builder = SchemaBuilder()

    // 预加载子类型 schema（触发 $defs 生成）
    CommandData.toJsonSchema()
    InvestigateData.toJsonSchema()
    ClarifyData.toJsonSchema()

    let typeProp = builder.enumSchema(["command", "investigate", "clarify"])
    builder.addProperty("type", typeProp, true, false)
    builder.addProperty("data", builder.objectSchema([], [], additionalProperties: None), true, false)
    builder.setRootType("termhelper.response")
    builder.toJsonSchema()
}

// ── 序列化 ──

/// LLMResponse → JSON 字符串
public func llmResponseToJsonString(resp: LLMResponse): String {
    llmResponseToJson(resp).toJsonString()
}

/// LLMResponse → JsonObject
public func llmResponseToJson(resp: LLMResponse): JsonObject {
    let root = JsonObject()
    match (resp) {
        case LLMResponse.Command(data) =>
            root.put("type", JsonString("command"))
            root.put("data", serializeData(data))
        case LLMResponse.Investigate(data) =>
            root.put("type", JsonString("investigate"))
            root.put("data", serializeData(data))
        case LLMResponse.Clarify(data) =>
            root.put("type", JsonString("clarify"))
            root.put("data", serializeData(data))
    }
    root
}

func serializeData(data: Object): JsonObject {
    match (data) {
        case cmd: CommandData => dataModelToJsonObject(cmd.serialize())
        case inv: InvestigateData => dataModelToJsonObject(inv.serialize())
        case clar: ClarifyData => dataModelToJsonObject(clar.serialize())
        case _ => JsonObject()
    }
}

// ── 反序列化 ──

/// 从 JSON 字符串严格解析 LLMResponse。失败返回 None。
/// 仅接受 schema 规定的结构，不做容错兜底。
public func parseLLMResponseJson(jsonText: String): ?LLMResponse {
    try {
        let jv = JsonValue.fromStr(jsonText)
        parseLLMResponse(jv.asObject())
    } catch (_: Exception) {
        None
    }
}

/// 从 JsonObject 解析 LLMResponse。
/// 首选 wire format: {"type": "...", "data": {...}}
/// json_object 降级：无 data 字段时整个 object 视为 data（扁平格式）
public func parseLLMResponse(root: JsonObject): ?LLMResponse {
    let typ = match (root.get("type")) {
        case Some(jv) => match (jv.kind()) {
            case JsString => jv.asString().getValue()
            case _ => return None
        }
        case None => return None
    }

    let dataObj: Option<JsonObject> = match (root.get("data")) {
        case Some(dataJv) =>
            match (dataJv.kind()) {
                case JsObject => Some(dataJv.asObject())
                case _ => return None
            }
        case None => Option<JsonObject>.None
    }

    // 首选 wire format，其次扁平格式（json_object 降级路径）
    let source = match (dataObj) {
        case Some(obj) => obj
        case None => root  // 扁平格式：去掉 type 字段后剩余字段即 data
    }

    // 规范化 safety level（LLM 常返回小写，枚举变体是 PascalCase）
    normalizeJsonForDeser(source)
    fillMissingDefaultFields(typ, source)

    let dm = DataModel.fromJson(source)
    deserializeData(typ, dm)
}

func fillMissingDefaultFields(typ: String, obj: JsonObject): Unit {
    if (typ == "command") {
        if (!obj.containsKey("factEdits")) {
            obj.put("factEdits", JsonArray())
        }
    } else if (typ == "investigate") {
        if (!obj.containsKey("contextUpdates")) {
            obj.put("contextUpdates", JsonObject())
        }
    }
}

func deserializeData(typ: String, dm: DataModel): ?LLMResponse {
    if (typ == "command") {
        try { Some(LLMResponse.Command(CommandData.deserialize(dm))) } catch (_: Exception) { None }
    } else if (typ == "investigate") {
        try { Some(LLMResponse.Investigate(InvestigateData.deserialize(dm))) } catch (_: Exception) { None }
    } else if (typ == "clarify") {
        try { Some(LLMResponse.Clarify(ClarifyData.deserialize(dm))) } catch (_: Exception) { None }
    } else {
        None
    }
}

/// 规范化 JSON 中与枚举变体名不一致的字符串值
func normalizeJsonForDeser(obj: JsonObject): Unit {
    // safety level: lowercase → PascalCase（"safe" → "Safe"）
    match (obj.get("safety")) {
        case Some(safetyJv) =>
            match (safetyJv.kind()) {
                case JsObject =>
                    let safetyObj = safetyJv.asObject()
                    match (safetyObj.get("level")) {
                        case Some(levelJv) =>
                            match (levelJv.kind()) {
                                case JsString =>
                                    let normalized = normalizeEnumCase(levelJv.asString().getValue())
                                    safetyObj.put("level", JsonString(normalized))
                                case _ => ()
                            }
                        case None => ()
                    }
                case _ => ()
            }
        case None => ()
    }
}

func normalizeEnumCase(s: String): String {
    // 若全小写则首字母大写，兼容 LLM 输出的 lowercase enum values
    if (s.size > 0 && s[0] >= b'a' && s[0] <= b'z') {
        var allLower = true
        for (i in 1..s.size) {
            if (s[i] < b'a' || s[i] > b'z') { allLower = false; break }
        }
        if (allLower) {
            var result = ""
            result += String(Rune(Int32(s[0] - 32)))
            result += s[1..]
            return result
        }
    }
    s
}

// ── DataModel ↔ JsonObject 桥接 ──

func dataModelToJsonObject(dm: DataModel): JsonObject {
    try { dm.toJson().asObject() } catch (_: Exception) { JsonObject() }
}

/// 将 DataModel 结构体的字段逐个转为 JsonObject 的 key-value 对
func dataModelStructToObject(dm: DataModel): JsonObject {
    try {
        dm.toJson().asObject()
    } catch (_: Exception) {
        JsonObject()
    }
}

// ── 工具函数（保留给其他模块使用）──

public func safetyLevelToString(level: SafetyLevel): String {
    match (level) {
        case SafetyLevel.Safe => "safe"
        case SafetyLevel.Caution => "caution"
        case SafetyLevel.Danger => "danger"
        case SafetyLevel.Privilege => "privilege"
    }
}

public func stringToSafetyLevel(level: String): SafetyLevel {
    if (level == "danger" || level == "Danger") {
        SafetyLevel.Danger
    } else if (level == "privilege" || level == "Privilege") {
        SafetyLevel.Privilege
    } else if (level == "caution" || level == "Caution") {
        SafetyLevel.Caution
    } else {
        SafetyLevel.Safe
    }
}
