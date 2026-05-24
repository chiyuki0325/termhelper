package termhelper.types

// ═══════════════════════════════════════════════════════════════
// PTY Agentic 工具集与状态
// ═══════════════════════════════════════════════════════════════

/// LLM 在 PTY agentic 循环中可选择的工具
public enum PtyTool {
    | Write(String, String)             // 写入内容 + 理由
    | AskUser(String, Bool)             // 需要用户提供信息 (问题, 是否敏感)
    | Wait(Int64)                       // 等待指定毫秒数后继续
    | Exit(String)                      // 命令已完成 (摘要)
    | Interrupt(String)                 // 检测到异常，建议中断 (原因)
}

/// PTY agentic 循环状态
public enum PtyLoopState {
    | WaitingOutput                     // 等待 PTY 新输出
    | LLMDecision                       // LLM 正在决策
    | AwaitingConfirm(String, String)   // 等待用户确认 (待写入内容, 理由)
    | AwaitingUserInput(String, Bool)   // 等待用户输入 (LLM 的问题, 是否敏感)
    | Finished(PtyResult)               // 已完成
    | Interrupted(String)               // 已中断
    | Throttled(Int64)                  // 节流等待中 (剩余毫秒)
    | RoundLimitReached                 // 达到单次会话 LLM 调用上限
}

/// PTY 执行结果
public struct PtyResult {
    public let exitCode: Int32
    public let output: String
    public let summary: String

    public init(exitCode: Int32, output: String, summary: String) {
        this.exitCode = exitCode
        this.output = output
        this.summary = summary
    }
}

// ═══════════════════════════════════════════════════════════════
// 后台任务 → TUI 主循环 单向通道事件
// ═══════════════════════════════════════════════════════════════

/// AppEvent — 后台任务 → TUI 通知
public enum AppEvent {
    | LLMChunk(String)                  // 流式响应片段 → Loading 屏实时更新
    | LLMDone(LLMResponse)              // 完整响应已解析
    | LLMError(String)                  // API 错误 (含重试耗尽)
    | LLMRetrying(Int64, String)        // 正在重试 (第n次, 原因)
    | SpawnOutput(String)               // spawn 输出行
    | SpawnDone(CommandResult)          // spawn 执行完毕
    | PtyScreenUpdate(String)           // PTY 虚拟终端全屏文本 (完整渲染帧)
    | PtyStateChange(PtyLoopState)      // PTY agentic 循环状态变更
    | PtyOverlayUpdate(PtyOverlayData)  // PTY overlay 面板内容更新
    | ClipboardDone                     // 复制完成
    | ModifySubmitted(String)           // 用户提交修改指示
    | ContextSaved                      // 上下文已持久化
}

/// 普通子进程执行结果（用于 spawn，非 PTY）
public struct CommandResult {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        this.exitCode = exitCode
        this.stdout = stdout
        this.stderr = stderr
    }
}

/// PTY overlay 面板数据
public struct PtyOverlayData {
    public let mode: PtyMode
    public let llmDecision: ?String
    public let pendingWrite: ?String
    public let pendingReason: ?String
    public let roundCount: Int64
    public let maxRounds: Int64

    public init(
        mode: PtyMode,
        llmDecision: ?String,
        pendingWrite: ?String,
        pendingReason: ?String,
        roundCount: Int64,
        maxRounds: Int64
    ) {
        this.mode = mode
        this.llmDecision = llmDecision
        this.pendingWrite = pendingWrite
        this.pendingReason = pendingReason
        this.roundCount = roundCount
        this.maxRounds = maxRounds
    }
}

/// PTY 模式
public enum PtyMode {
    | Confirm       // 默认模式：逐次确认
    | FullAuto      // 全自动模式
}
