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
