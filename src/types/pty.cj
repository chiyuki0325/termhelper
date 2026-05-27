package termhelper.types

import naivejson.macros.*
import naivejson.schema.*
import naivejson.schema.model.*
import naivejson.schema.render.*
import stdx.serialization.serialization.DataModel
import stdx.serialization.serialization.DataModelStruct
import stdx.serialization.serialization.DataModelString
import stdx.serialization.serialization.DataModelNull
import stdx.serialization.serialization.DataModelException
import stdx.serialization.serialization.Serializable
import stdx.serialization.serialization.field

/// PTY 工具集（不含 @JsonAdapter — payloaded enum）
public enum PtyTool {
    | Write(String, String)
    | AskUser(String, Bool)
    | Wait(Int64)
    | Exit(String)
    | Interrupt(String)
}

/// PTY 循环状态（不含 @JsonAdapter — payloaded enum）
public enum PtyLoopState {
    | WaitingOutput
    | LLMDecision
    | AwaitingConfirm(String, String)
    | AwaitingUserInput(String, Bool)
    | Finished(PtyResult)
    | Interrupted(String)
    | Throttled(Int64)
    | RoundLimitReached
}

@JsonAdapter
public class PtyResult {
    public var exitCode: Int32 = 0
    public var output: String = ""
    public var summary: String = ""
}

/// AppEvent（不含 @JsonAdapter — payloaded enum）
public enum AppEvent {
    | LLMChunk(String)
    | LLMDone(LLMResponse)
    | LLMError(String)
    | LLMRetrying(Int64, String)
    | SpawnOutput(String)
    | SpawnDone(CommandResult)
    | PtyScreenUpdate(String)
    | PtyStateChange(PtyLoopState)
    | PtyOverlayUpdate(PtyOverlayData)
    | ClipboardDone
    | ModifySubmitted(String)
    | ContextSaved
}

@JsonAdapter
public class CommandResult {
    public var exitCode: Int32 = 0
    public var stdout: String = ""
    public var stderr: String = ""
}

@JsonAdapter
public class PtyOverlayData {
    public var mode: PtyMode = PtyMode.Confirm
    @JsonIgnoreNull
    public var llmDecision: Option<String> = None
    @JsonIgnoreNull
    public var pendingWrite: Option<String> = None
    @JsonIgnoreNull
    public var pendingReason: Option<String> = None
    public var roundCount: Int64 = 0
    public var maxRounds: Int64 = 50
}

@JsonAdapter
public enum PtyMode {
    | Confirm
    | FullAuto
}
