package termhelper.util

import termhelper.types.*
import std.collection.*
import stdx.encoding.json.*

/// JSON Schema for the unified LLMResponse wire shape:
/// { "type": "command" | "investigate" | "clarify", "data": { ... } }
public func llmResponseSchema(): String {
    let root = JsonObject()
    root.put("type", JsonString("object"))
    root.put("additionalProperties", JsonBool(false))

    let props = JsonObject()
    let typeProp = JsonObject()
    typeProp.put("type", JsonString("string"))
    let typeEnum = JsonArray()
    typeEnum.add(JsonString("command"))
    typeEnum.add(JsonString("investigate"))
    typeEnum.add(JsonString("clarify"))
    typeProp.put("enum", typeEnum)
    props.put("type", typeProp)

    let dataProp = JsonObject()
    dataProp.put("type", JsonString("object"))
    dataProp.put("description", JsonString("Variant payload. For command: command/explanation/interactive/safety. For investigate: reason/commands. For clarify: question."))
    props.put("data", dataProp)
    root.put("properties", props)

    let required = JsonArray()
    required.add(JsonString("type"))
    required.add(JsonString("data"))
    root.put("required", required)
    root.toJsonString()
}

public func llmResponseToJsonString(resp: LLMResponse): String {
    llmResponseToJson(resp).toJsonString()
}

public func llmResponseToJson(resp: LLMResponse): JsonObject {
    let root = JsonObject()
    match (resp) {
        case LLMResponse.Command(data) =>
            root.put("type", JsonString("command"))
            root.put("data", commandDataToJson(data))
        case LLMResponse.Investigate(data) =>
            root.put("type", JsonString("investigate"))
            root.put("data", investigateDataToJson(data))
        case LLMResponse.Clarify(data) =>
            root.put("type", JsonString("clarify"))
            let obj = JsonObject()
            obj.put("question", JsonString(data.question))
            root.put("data", obj)
    }
    root
}

public func parseLLMResponseJson(jsonText: String): ?LLMResponse {
    try {
        let root = JsonValue.fromStr(jsonText).asObject()
        parseLLMResponse(root)
    } catch (_: Exception) {
        None
    }
}

public func parseLLMResponse(root: JsonObject): ?LLMResponse {
    let typ = jsonGetString(root, "type", "")
    match (root.get("data")) {
        case Some(dataJv) =>
            let data = dataJv.asObject()
            if (typ == "command") {
                Some(LLMResponse.Command(parseCommandData(data)))
            } else if (typ == "investigate") {
                Some(LLMResponse.Investigate(parseInvestigateData(data)))
            } else if (typ == "clarify") {
                Some(LLMResponse.Clarify(ClarifyData(jsonGetString(data, "question", ""))))
            } else {
                None
            }
        case None => parseFlatLLMResponse(root, typ)
    }
}

func parseFlatLLMResponse(root: JsonObject, typ: String): ?LLMResponse {
    if (typ == "command") {
        Some(LLMResponse.Command(parseCommandData(root)))
    } else if (typ == "investigate") {
        Some(LLMResponse.Investigate(parseInvestigateData(root)))
    } else if (typ == "clarify") {
        Some(LLMResponse.Clarify(ClarifyData(jsonGetString(root, "question", ""))))
    } else {
        None
    }
}

func commandDataToJson(data: CommandData): JsonObject {
    let obj = JsonObject()
    obj.put("command", JsonString(data.command))
    obj.put("explanation", explanationToJson(data.explanation))
    obj.put("interactive", JsonBool(data.interactive))
    obj.put("safety", safetyToJson(data.safety))
    obj
}

func explanationToJson(explanation: Explanation): JsonObject {
    let obj = JsonObject()
    obj.put("summary", JsonString(explanation.summary))
    let arr = JsonArray()
    for (i in 0..explanation.breakdown.size) {
        let item = explanation.breakdown[i]
        let itemObj = JsonObject()
        itemObj.put("component", JsonString(item.component))
        itemObj.put("explanation", JsonString(item.explanation))
        arr.add(itemObj)
    }
    obj.put("breakdown", arr)
    obj
}

func safetyToJson(safety: SafetyInfo): JsonObject {
    let obj = JsonObject()
    obj.put("level", JsonString(safetyLevelToString(safety.level)))
    let arr = JsonArray()
    for (i in 0..safety.warnings.size) { arr.add(JsonString(safety.warnings[i])) }
    obj.put("warnings", arr)
    obj
}

func investigateDataToJson(data: InvestigateData): JsonObject {
    let obj = JsonObject()
    obj.put("reason", JsonString(data.reason))
    let arr = JsonArray()
    for (i in 0..data.commands.size) {
        let cmd = data.commands[i]
        let cmdObj = JsonObject()
        cmdObj.put("command", JsonString(cmd.command))
        cmdObj.put("rationale", JsonString(cmd.rationale))
        cmdObj.put("authorized", JsonBool(cmd.authorized))
        arr.add(cmdObj)
    }
    obj.put("commands", arr)
    obj
}

func parseCommandData(obj: JsonObject): CommandData {
    let explanation = match (obj.get("explanation")) {
        case Some(jv) => match (jv.kind()) {
            case JsObject => parseExplanation(jv.asObject())
            case JsString => Explanation(jv.asString().getValue(), parseFlatBreakdown(obj))
            case _ => Explanation("", parseFlatBreakdown(obj))
        }
        case None => Explanation("", parseFlatBreakdown(obj))
    }
    let safety = match (obj.get("safety")) {
        case Some(jv) => match (jv.kind()) {
            case JsObject => parseSafety(jv.asObject())
            case JsString => SafetyInfo(stringToSafetyLevel(jv.asString().getValue()), parseFlatWarnings(obj))
            case _ => SafetyInfo(SafetyLevel.Safe, ArrayList<String>())
        }
        case None => SafetyInfo(SafetyLevel.Safe, ArrayList<String>())
    }
    CommandData(
        jsonGetString(obj, "command", ""),
        explanation,
        jsonGetBool(obj, "interactive", false),
        safety
    )
}

func parseFlatBreakdown(obj: JsonObject): ArrayList<BreakdownItem> {
    let items = ArrayList<BreakdownItem>()
    match (obj.get("breakdown")) {
        case Some(jv) =>
            try {
                let arr = jv.asArray()
                for (i in 0..arr.size()) {
                    match (arr.get(i)) {
                        case Some(itemJv) =>
                            let itemObj = itemJv.asObject()
                            let explanation = jsonGetString(itemObj, "explanation", jsonGetString(itemObj, "purpose", ""))
                            items.add(BreakdownItem(jsonGetString(itemObj, "component", ""), explanation))
                        case None => ()
                    }
                }
            } catch (_: Exception) { () }
        case None => ()
    }
    if (items.size > 0) { items } else { parseComponents(obj) }
}

func parseComponents(obj: JsonObject): ArrayList<BreakdownItem> {
    let items = ArrayList<BreakdownItem>()
    match (obj.get("components")) {
        case Some(jv) =>
            try {
                let components = jv.asObject()
                for ((k, v) in components.getFields()) {
                    match (v.kind()) {
                        case JsString => items.add(BreakdownItem(k, v.asString().getValue()))
                        case _ => items.add(BreakdownItem(k, v.toJsonString()))
                    }
                }
            } catch (_: Exception) { () }
        case None => ()
    }
    items
}

func parseFlatWarnings(obj: JsonObject): ArrayList<String> {
    let warnings = ArrayList<String>()
    match (obj.get("warnings")) {
        case Some(jv) =>
            try {
                let arr = jv.asArray()
                for (i in 0..arr.size()) {
                    match (arr.get(i)) {
                        case Some(wJv) =>
                            match (wJv.kind()) {
                                case JsString => warnings.add(wJv.asString().getValue())
                                case _ => warnings.add(wJv.toJsonString())
                            }
                        case None => ()
                    }
                }
            } catch (_: Exception) { () }
        case None => ()
    }
    warnings
}

func parseExplanation(obj: JsonObject): Explanation {
    let items = ArrayList<BreakdownItem>()
    match (obj.get("breakdown")) {
        case Some(arrJv) =>
            let arr = arrJv.asArray()
            for (i in 0..arr.size()) {
                match (arr.get(i)) {
                    case Some(itemJv) =>
                        let itemObj = itemJv.asObject()
                        items.add(BreakdownItem(
                            jsonGetString(itemObj, "component", ""),
                            jsonGetString(itemObj, "explanation", "")
                        ))
                    case None => ()
                }
            }
        case None => ()
    }
    Explanation(jsonGetString(obj, "summary", ""), items)
}

func parseSafety(obj: JsonObject): SafetyInfo {
    let warnings = ArrayList<String>()
    match (obj.get("warnings")) {
        case Some(arrJv) =>
            let arr = arrJv.asArray()
            for (i in 0..arr.size()) {
                match (arr.get(i)) {
                    case Some(wJv) =>
                        match (wJv.kind()) {
                            case JsString => warnings.add(wJv.asString().getValue())
                            case _ => ()
                        }
                    case None => ()
                }
            }
        case None => ()
    }
    SafetyInfo(stringToSafetyLevel(jsonGetString(obj, "level", "safe")), warnings)
}

func parseInvestigateData(obj: JsonObject): InvestigateData {
    let commands = ArrayList<DiagnosticCommand>()
    match (obj.get("commands")) {
        case Some(arrJv) =>
            let arr = arrJv.asArray()
            for (i in 0..arr.size()) {
                match (arr.get(i)) {
                    case Some(cmdJv) =>
                        let cmdObj = cmdJv.asObject()
                        commands.add(DiagnosticCommand(
                            jsonGetString(cmdObj, "command", ""),
                            jsonGetString(cmdObj, "rationale", "")
                        ))
                    case None => ()
                }
            }
        case None => ()
    }
    InvestigateData(jsonGetString(obj, "reason", ""), commands)
}

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

func jsonGetString(obj: JsonObject, key: String, default: String): String {
    match (obj.get(key)) {
        case Some(jv) => match (jv.kind()) {
            case JsString => jv.asString().getValue()
            case _ => default
        }
        case None => default
    }
}

func jsonGetBool(obj: JsonObject, key: String, default: Bool): Bool {
    match (obj.get(key)) {
        case Some(jv) => match (jv.kind()) {
            case JsBool => jv.asBool().getValue()
            case _ => default
        }
        case None => default
    }
}
