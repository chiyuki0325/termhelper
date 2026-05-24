package termhelper.types

import std.collection.ArrayList

// ═══════════════════════════════════════════════════════════════
// LLM 结构化响应类型
// ═══════════════════════════════════════════════════════════════

/// LLM 响应的三种类型
public enum LLMResponse {
    | Command(CommandData)
    | Investigate(InvestigateData)
    | Clarify(ClarifyData)
}

/// 命令数据
public struct CommandData {
    public let command: String
    public let explanation: Explanation
    public let interactive: Bool
    public let safety: SafetyInfo

    public init(command: String, explanation: Explanation, interactive: Bool, safety: SafetyInfo) {
        this.command = command
        this.explanation = explanation
        this.interactive = interactive
        this.safety = safety
    }
}

/// 命令分解说明
public struct Explanation {
    public let summary: String
    public let breakdown: ArrayList<BreakdownItem>

    public init(summary: String, breakdown: ArrayList<BreakdownItem>) {
        this.summary = summary
        this.breakdown = breakdown
    }
}

/// 命令组件说明项
public struct BreakdownItem {
    public let component: String
    public let explanation: String

    public init(component: String, explanation: String) {
        this.component = component
        this.explanation = explanation
    }
}

/// 安全信息
public struct SafetyInfo {
    public let level: SafetyLevel
    public let warnings: ArrayList<String>

    public init(level: SafetyLevel, warnings: ArrayList<String>) {
        this.level = level
        this.warnings = warnings
    }
}

/// 安全等级
public enum SafetyLevel {
    | Safe
    | Caution
    | Danger
    | Privilege
}

/// 环境调查数据
public struct InvestigateData {
    public let reason: String
    public let commands: ArrayList<DiagnosticCommand>

    public init(reason: String, commands: ArrayList<DiagnosticCommand>) {
        this.reason = reason
        this.commands = commands
    }
}

/// 诊断命令
public struct DiagnosticCommand {
    public let command: String
    public let rationale: String
    public var authorized: Bool

    public init(command: String, rationale: String) {
        this.command = command
        this.rationale = rationale
        this.authorized = false
    }
}

/// 澄清提问数据
public struct ClarifyData {
    public let question: String

    public init(question: String) {
        this.question = question
    }
}
