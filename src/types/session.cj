package termhelper.types

import naivejson.macros.*
import naivejson.schema.*
import naivejson.schema.model.*
import naivejson.schema.render.*
import std.collection.HashMap
import std.collection.ArrayList
import stdx.serialization.serialization.DataModel
import stdx.serialization.serialization.DataModelStruct
import stdx.serialization.serialization.DataModelString
import stdx.serialization.serialization.DataModelException
import stdx.serialization.serialization.Serializable
import stdx.serialization.serialization.field

@JsonAdapter
public class EnvironmentFact {
    public var text: String = ""
    public var source: String = ""
    public var lastVerified: Int64 = 0
}

@JsonAdapter
public enum MessageRole {
    | System
    | User
    | Assistant
    | Tool
}

@JsonAdapter
public class Message {
    public var role: MessageRole = MessageRole.User
    public var content: String = ""
    /// tool 消息关联的 tool_use id（用于 multi-turn tool calling，运行时字段不序列化）
    @JsonIgnore
    public var toolCallId: Option<String> = None
    /// assistant 消息中的 tool_use 列表（用于 multi-turn tool calling，运行时字段不序列化）
    @JsonIgnore
    public var toolCalls: Option<ArrayList<ToolCall>> = None
}

/// 环境上下文（跨会话持久化）
@JsonAdapter
public class EnvironmentContext {
    public var version: Int64 = 4
    public var facts: HashMap<String, EnvironmentFact> = HashMap<String, EnvironmentFact>()
    public var lastUpdated: Int64 = 0
}
