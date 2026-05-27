package termhelper.types

import naivejson.macros.*
import naivejson.schema.*
import naivejson.schema.model.*
import naivejson.schema.render.*
import std.collection.HashMap
import stdx.serialization.serialization.DataModel
import stdx.serialization.serialization.DataModelStruct
import stdx.serialization.serialization.DataModelString
import stdx.serialization.serialization.DataModelNull
import stdx.serialization.serialization.DataModelException
import stdx.serialization.serialization.Serializable
import stdx.serialization.serialization.field

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
}

/// 环境上下文（跨会话持久化）
@JsonAdapter
public class EnvironmentContext {
    public var version: Int64 = 2
    @JsonIgnoreNull
    public var os: Option<String> = None
    @JsonIgnoreNull
    public var distro: Option<String> = None
    @JsonIgnoreNull
    public var packageManager: Option<String> = None
    public var shell: String = ""
    public var tools: HashMap<String, String> = HashMap<String, String>()
    public var extras: HashMap<String, String> = HashMap<String, String>()
    public var lastUpdated: Int64 = 0

    public static func empty(shell: String): EnvironmentContext {
        let ctx = EnvironmentContext()
        ctx.shell = shell
        ctx
    }
}
