package termhelper.types

import naivejson.macros.*
import naivejson.schema.*
import naivejson.schema.model.*
import naivejson.schema.render.*
import std.collection.ArrayList
import std.collection.HashMap
import stdx.serialization.serialization.DataModel
import stdx.serialization.serialization.DataModelStruct
import stdx.serialization.serialization.DataModelString
import stdx.serialization.serialization.DataModelException
import stdx.serialization.serialization.Serializable
import stdx.serialization.serialization.field

/// LLM 响应（手动 dispatch，非 @JsonAdapter）
public enum LLMResponse {
    | Command(CommandData)
    | Investigate(InvestigateData)
    | Clarify(ClarifyData)
}

@JsonAdapter
public class CommandData {
    public var command: String = ""
    public var explanation: Explanation = Explanation()
    public var interactive: Bool = false
    public var safety: SafetyInfo = SafetyInfo()
    public var factEdits: ArrayList<FactEdit> = ArrayList<FactEdit>()
}

@JsonAdapter
public class FactEdit {
    public var op: String = ""
    public var id: String = ""
    public var oldText: String = ""
    public var newText: String = ""
    public var source: String = ""
    public var reason: String = ""
}

@JsonAdapter
public class Explanation {
    public var summary: String = ""
    public var breakdown: ArrayList<BreakdownItem> = ArrayList<BreakdownItem>()
}

@JsonAdapter
public class BreakdownItem {
    public var component: String = ""
    public var explanation: String = ""
}

@JsonAdapter
public class SafetyInfo {
    public var level: SafetyLevel = SafetyLevel.Safe
    public var warnings: ArrayList<String> = ArrayList<String>()
}

@JsonAdapter
public enum SafetyLevel {
    | Safe
    | Caution
    | Danger
    | Privilege
}

/// FR-03: 环境调查 — contextUpdates 由 ContextManager.update() 合并到 context.json
@JsonAdapter
public class InvestigateData {
    public var reason: String = ""
    public var commands: ArrayList<DiagnosticCommand> = ArrayList<DiagnosticCommand>()
    public var contextUpdates: HashMap<String, String> = HashMap<String, String>()
}

@JsonAdapter
public class DiagnosticCommand {
    public var command: String = ""
    public var rationale: String = ""
    @JsonIgnore
    public var authorized: Bool = false
}

@JsonAdapter
public class ClarifyData {
    public var question: String = ""
}

// ── Tool Calling 共享类型 ──

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

/// Tool Choice
public enum ToolChoice {
    | Auto
    | Required
    | NoTool
}
