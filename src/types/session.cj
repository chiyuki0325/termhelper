package termhelper.types

import std.collection.HashMap

// ═══════════════════════════════════════════════════════════════
// 会话模型
// ═══════════════════════════════════════════════════════════════

/// 消息角色
public enum MessageRole {
    | System
    | User
    | Assistant
    | Tool
}

/// 对话消息
public struct Message {
    public let role: MessageRole
    public let content: String

    public init(role: MessageRole, content: String) {
        this.role = role
        this.content = content
    }
}

/// 环境上下文（跨会话持久化）
public struct EnvironmentContext {
    public let version: Int64
    public let os: ?String
    public let distro: ?String
    public let packageManager: ?String
    public let shell: String
    public let tools: HashMap<String, String>
    public let extras: HashMap<String, String>
    public let lastUpdated: Int64

    public init(
        version: Int64,
        os: ?String,
        distro: ?String,
        packageManager: ?String,
        shell: String,
        tools: HashMap<String, String>,
        extras: HashMap<String, String>,
        lastUpdated: Int64
    ) {
        this.version = version
        this.os = os
        this.distro = distro
        this.packageManager = packageManager
        this.shell = shell
        this.tools = tools
        this.extras = extras
        this.lastUpdated = lastUpdated
    }

    /// 创建空的环境上下文（首次使用）
    public static func empty(shell: String): EnvironmentContext {
        EnvironmentContext(
            2,
            None,
            None,
            None,
            shell,
            HashMap<String, String>(),
            HashMap<String, String>(),
            0
        )
    }
}
