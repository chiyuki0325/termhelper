package termhelper.core

import termhelper.types.*
import termhelper.adapters.*
import termhelper.infra.*
import termhelper.i18n.*
import termhelper.util.*
import std.collection.*
import std.sync.*
import std.fs.*
import std.env.*

// ═══════════════════════════════════════════════════════════════
// PTY Agentic 循环 — 阶段 6 核心模块
// 后台线程驱动 PTY + LLM tool-calling 循环，通过回调函数
// 与 TUI 单向通信；通过 Mutex 保护的字段接收 TUI 的用户决策。
// ═══════════════════════════════════════════════════════════════

// ── FFI 声明与常量（必须在类定义之前）──

@C
struct Timespec {
    var tv_sec: Int64 = 0
    var tv_nsec: Int64 = 0

    public init(sec: Int64, nsec: Int64) {
        this.tv_sec = sec; this.tv_nsec = nsec
    }
}

let CLOCK_MONOTONIC: Int32 = 1

foreign func clock_gettime(clk_id: Int32, tp: CPointer<Timespec>): Int32
foreign func usleep(usec: UInt64): Int32

// ── PTY Debug Log ──
// TERMHELPER_PTY_DEBUG=1 启用，写入 /tmp/termhelper_pty_debug.log
// 监控: tail -f /tmp/termhelper_pty_debug.log

let PTY_DBG_LOG: String = "/tmp/termhelper_pty_debug.log"
var ptyDbgFile: ?File = None

func ptyDebugEnabled(): Bool { match (ptyDbgFile) { case Some(_) => true; case None => false } }

func ptyDebugInit(): Unit {
    match (getVariable("TERMHELPER_PTY_DEBUG")) {
        case Some(v) => if (v != "1") { return }
        case None => return
    }
    try {
        let f = File(Path(PTY_DBG_LOG), Write)
        ptyDbgFile = Some(f)
        let msg = "[pty_debug] log opened\n"
        f.write(msg.toArray())
        f.flush()
    } catch (_: Exception) {
        ()
    }
}

func ptyDebugLog(msg: String): Unit {
    match (ptyDbgFile) {
        case Some(f) =>
            let ts = monotonicMs()
            let line = "[${ts}] ${msg}\n"
            f.write(line.toArray())
            f.flush()
        case None => ()
    }
}

func ptyDebugClose(): Unit {
    match (ptyDbgFile) {
        case Some(f) =>
            ptyDebugLog("log closing")
            f.close()
            ptyDbgFile = None
        case None => ()
    }
}

// ── 工具定义：PtyTool → ToolDefinition ──

func ptyToolDefinitions(): ArrayList<ToolDefinition> {
    let tools = ArrayList<ToolDefinition>()

    tools.add(ToolDefinition(
        "Write",
        "Write text to the terminal. Use this when the program is waiting for input.",
        "{\"type\":\"object\",\"properties\":{\"content\":{\"type\":\"string\",\"description\":\"Text to write to the terminal\"},\"reason\":{\"type\":\"string\",\"description\":\"Brief explanation of why this input is needed\"}},\"required\":[\"content\",\"reason\"]}"
    ))
    tools.add(ToolDefinition(
        "AskUser",
        "Ask the user for information you don't know (passwords, choices, etc).",
        "{\"type\":\"object\",\"properties\":{\"question\":{\"type\":\"string\",\"description\":\"The question for the user\"},\"sensitive\":{\"type\":\"boolean\",\"description\":\"True for passwords/tokens that should be masked\"}},\"required\":[\"question\",\"sensitive\"]}"
    ))
    tools.add(ToolDefinition(
        "Wait",
        "Wait for the terminal output to settle before deciding the next action.",
        "{\"type\":\"object\",\"properties\":{\"milliseconds\":{\"type\":\"integer\",\"description\":\"Duration in ms (500-30000)\"}},\"required\":[\"milliseconds\"]}"
    ))
    tools.add(ToolDefinition(
        "Exit",
        "The command has finished. Provide a summary of what happened.",
        "{\"type\":\"object\",\"properties\":{\"summary\":{\"type\":\"string\",\"description\":\"Summary of the command execution result\"}},\"required\":[\"summary\"]}"
    ))
    tools.add(ToolDefinition(
        "Interrupt",
        "Stop the command because it is stuck, unsafe, or asking for unexpected sensitive input.",
        "{\"type\":\"object\",\"properties\":{\"reason\":{\"type\":\"string\",\"description\":\"Why the command should be interrupted\"}},\"required\":[\"reason\"]}"
    ))
    tools
}

// ── PtyAgentLoop ──

/// PTY agentic 循环控制器。
/// 在后台线程中运行，通过 PtyAgentLoop.run() 启动。
/// TUI 通过 submitUserAction() / requestInterrupt() / switchMode() 控制。
public class PtyAgentLoop {
    // ── PTY 状态 ──
    private var pty: ?Pty
    private var textBuf: ?PtyTextBuffer
    private var llmBuf: ?PtyLlmContextBuffer
    private var command: String

    // ── 循环状态 ──
    private var roundCount: Int64
    private var maxRounds: Int64
    private var mode: PtyMode
    private var loopState: PtyLoopState
    private var totalInputTokens: Int64
    private var totalOutputTokens: Int64

    // ── 调度与成本控制 ──
    private var lastDecisionAt: Int64
    private var lastOutputAt: Int64
    private var firstDirtyOutputAt: Int64
    private var nextEligibleAt: Int64
    private var dirtyOutput: Bool
    private var minDecisionIntervalMs: Int64
    private var quietWindowMs: Int64
    private var maxWaitAfterOutputMs: Int64
    private var decisionHistoryLimit: Int64

    // ── 通信 ──
    private let onEvent: (AppEvent) -> Unit  // 回调：发送事件给 TUI
    private let provider: LLMProvider
    private let config: Config
    private let context: EnvironmentContext

    // ── TUI → Agent 同步 ──
    private let mtx: Mutex
    private var userAction: ?String
    private var interruptRequested: Bool
    private var modeSwitchRequested: ?PtyMode
    private var resizeRequested: ?(UInt16, UInt16)

    // ── LLM 对话历史（仅 PTY agent 上下文）──
    private var decisionHistory: ArrayList<Message>

    // ── 当前 tool call（用于 tool result 关联 tool_call_id）──
    private var lastToolCall: ?ToolCall

    // ── 敏感内容脱敏 ──
    private var redactedPatterns: ArrayList<String>

    public init(onEvent: (AppEvent) -> Unit, provider: LLMProvider, config: Config, context: EnvironmentContext) {
        this.pty = None
        this.textBuf = None
        this.llmBuf = None
        this.command = ""
        this.roundCount = 0
        this.maxRounds = config.execution.ptyMaxRounds
        this.mode = if (config.execution.ptyDefaultMode == "full_auto") {
            PtyMode.FullAuto
        } else {
            PtyMode.Confirm
        }
        this.loopState = PtyLoopState.WaitingOutput
        this.totalInputTokens = 0
        this.totalOutputTokens = 0
        this.lastDecisionAt = 0
        this.lastOutputAt = 0
        this.firstDirtyOutputAt = 0
        this.nextEligibleAt = 0
        this.dirtyOutput = false
        this.minDecisionIntervalMs = config.execution.ptyMinIntervalMs
        this.quietWindowMs = config.execution.ptyQuietWindowMs
        this.maxWaitAfterOutputMs = config.execution.ptyMaxWaitAfterOutputMs
        this.decisionHistoryLimit = config.execution.ptyDecisionHistoryLimit
        this.onEvent = onEvent
        this.provider = provider
        this.config = config
        this.context = context
        this.mtx = Mutex()
        this.userAction = None
        this.interruptRequested = false
        this.modeSwitchRequested = None
        this.resizeRequested = None
        this.decisionHistory = ArrayList<Message>()
        this.lastToolCall = None
        this.redactedPatterns = ArrayList<String>()
    }

    // ── 公开方法（TUI 线程调用）──

    public func submitUserAction(action: String): Unit {
        synchronized(mtx) { userAction = Some(action) }
    }

    public func requestInterrupt(): Unit {
        synchronized(mtx) { interruptRequested = true }
    }

    public func switchMode(newMode: PtyMode): Unit {
        synchronized(mtx) { modeSwitchRequested = Some(newMode) }
    }

    public func requestResize(cols: UInt16, rows: UInt16): Unit {
        synchronized(mtx) { resizeRequested = Some((cols, rows)) }
    }

    public func getState(): PtyLoopState { loopState }
    public func getMode(): PtyMode { mode }
    public func getRound(): Int64 { roundCount }

    // ── 主入口（后台线程调用）──

    public func run(command: String, terminalRows: UInt16, terminalCols: UInt16): PtyResult {
        this.command = command
        this.roundCount = 0
        this.totalInputTokens = 0
        this.totalOutputTokens = 0
        this.decisionHistory.clear()
        this.lastToolCall = None
        this.lastDecisionAt = 0
        this.lastOutputAt = 0
        this.firstDirtyOutputAt = 0
        this.nextEligibleAt = 0
        this.dirtyOutput = false

        // 初始化 debug FIFO
        ptyDebugInit()
        ptyDebugLog("=== PTY agentic start ===")
        ptyDebugLog("command: ${command}")
        ptyDebugLog("terminal size: ${terminalRows}x${terminalCols}")

        // 1. 创建 PTY 和虚拟终端缓冲区
        match (Pty.create(terminalRows, terminalCols)) {
            case Some(p) =>
                this.pty = Some(p)
                ptyDebugLog("PTY created ok, slave=${p.slavePath}")
            case None =>
                ptyDebugLog("PTY create FAILED")
                let result = PtyResult()
                result.exitCode = -1
                result.summary = uiText("pty_create_failed")
                onEvent(AppEvent.PtyStateChange(PtyLoopState.Finished(result)))
                return result
        }
        let p = pty.getOrThrow()
        this.textBuf = Some(PtyTextBuffer())
        this.llmBuf = Some(PtyLlmContextBuffer(
            config.execution.ptyLlmCompactThresholdBytes,
            config.execution.ptyLlmCompactKeepBytes,
            config.execution.ptyContextMaxBytes))

        // 2. Spawn 交互式命令
        ptyDebugLog("spawning child: ${command}")
        if (!p.spawnChild(command)) {
            ptyDebugLog("spawn FAILED")
            let result = PtyResult()
            result.exitCode = -1
            result.summary = uiText("pty_spawn_failed")
            onEvent(AppEvent.PtyStateChange(PtyLoopState.Finished(result)))
            p.close()
            return result
        }

        // 3. 发送初始浮层面板状态
        pushOverlayUpdate()

        // 4. 进入主循环
        var running = true
        var result = PtyResult()

        while (running) {
            if (checkInterrupt()) {
                loopState = PtyLoopState.Interrupted(uiText("pty_interrupted_by_user"))
                onEvent(AppEvent.PtyStateChange(loopState))
                running = false
                continue
            }

            processModeSwitch()
            processResize()

            let exited = p.childExited()
            let hasOutput = readAndProcessOutput(p)

            if (exited && !hasOutput) {
                ptyDebugLog("child exited, round=${roundCount}, exitCode=${p.getExitCode()}")
                flushLlmOpenLine()
                if (roundCount > 0) {
                    result = runFinalLlmRound(p)
                } else {
                    result = collectResult(p)
                }
                ptyDebugLog("loop finished: exitCode=${result.exitCode} summary=${result.summary}")
                loopState = PtyLoopState.Finished(result)
                onEvent(AppEvent.PtyStateChange(loopState))
                running = false
                continue
            }

            if (!shouldCallLlm(exited)) {
                loopState = PtyLoopState.Throttled(nextDelayMs())
                onEvent(AppEvent.PtyStateChange(loopState))
                pushOverlayUpdate()
                let bufSize = match (textBuf) { case Some(b) => b.size(); case None => 0 }
                let llmSize = match (llmBuf) { case Some(b) => b.rawSize(); case None => 0 }
                ptyDebugLog("scheduled wait: round=${roundCount} raw=${bufSize} llm=${llmSize} dirty=${dirtyOutput}")
                sleepMs(100)
                continue
            }

            loopState = PtyLoopState.LLMDecision
            onEvent(AppEvent.PtyStateChange(loopState))
            let bufSize2 = match (textBuf) { case Some(b) => b.size(); case None => 0 }
            let llmSize2 = match (llmBuf) { case Some(b) => b.rawSize(); case None => 0 }
            ptyDebugLog("→ LLM round ${roundCount + 1} raw=${bufSize2} llm=${llmSize2}")

            match (callLlmForDecision()) {
                case Some(tool) =>
                    ptyDebugLog("← LLM tool: ${toolToolName(tool)} input=${totalInputTokens} output=${totalOutputTokens}")
                    if (!executeTool(p, tool)) {
                        ptyDebugLog("executeTool returned false, ending loop")
                        running = false
                        result = collectResult(p)
                        loopState = PtyLoopState.Finished(result)
                        onEvent(AppEvent.PtyStateChange(loopState))
                    }
                case None => sleepMs(1000)
            }

            if (roundCount >= maxRounds && running) {
                loopState = PtyLoopState.RoundLimitReached
                onEvent(AppEvent.PtyStateChange(loopState))
                let action = waitForUserAction()
                match (action) {
                    case "continue" => roundCount = 0
                    case "interrupt" =>
                        running = false
                        loopState = PtyLoopState.Interrupted(uiText("pty_round_limit_interrupted"))
                        onEvent(AppEvent.PtyStateChange(loopState))
                    case "manual" =>
                        running = false
                        result = PtyResult()
                        result.summary = uiText("pty_switched_to_manual")
                        loopState = PtyLoopState.Finished(result)
                        onEvent(AppEvent.PtyStateChange(loopState))
                    case _ => ()
                }
            }
        }

        p.close()
        ptyDebugLog("=== PTY agentic end: exitCode=${result.exitCode} rounds=${roundCount} tokens=${totalInputTokens}+${totalOutputTokens} ===")
        ptyDebugClose()
        result
    }

    // ── 内部方法 ──

    private func readAndProcessOutput(p: Pty): Bool {
        let data = p.tryRead(65536)
        if (data.size == 0) { return false }

        ptyDebugLog("read output: ${data.size} bytes")

        // 先发送原始输出给 TUI（含 ANSI 转义序列，供 Cell→Span 渲染）
        onEvent(AppEvent.PtyScreenUpdate(data))

        // 检测密码回显模式（在发送给 LLM 之前脱敏）
        detectPasswordEcho(data)

        // 再更新本地文本缓冲区（供 LLM 上下文 + 节流用）
        match (textBuf) {
            case Some(buf) => buf.append(data)
            case None => ()
        }
        match (llmBuf) {
            case Some(buf) =>
                if (buf.append(data)) {
                    markDirtyOutput()
                }
            case None => ()
        }
        true
    }

    private func markDirtyOutput(): Unit {
        let now = monotonicMs()
        lastOutputAt = now
        if (!dirtyOutput) {
            dirtyOutput = true
            firstDirtyOutputAt = now
        }
    }

    private func flushLlmOpenLine(): Unit {
        match (llmBuf) {
            case Some(buf) =>
                if (buf.finishOpenLine()) {
                    markDirtyOutput()
                }
            case None => ()
        }
    }

    /// 检测 PTY 输出中的密码回显模式，将匹配内容加入脱敏列表
    private func detectPasswordEcho(data: String): Unit {
        // ANSI 转义序列剥离后的纯文本用于检测
        let plain = stripAnsiEscapes(data)
        let lines = plain.split("\n")
        for (line in lines) {
            let trimmed = line.trimAscii()
            if (trimmed.size >= 4 && isAllMasked(trimmed)) {
                // 连续 * 或 • 或 ● 字符 → 密码回显
                if (!redactedPatterns.contains(trimmed)) {
                    redactedPatterns.add(trimmed)
                }
            }
        }
    }

    /// 检查字符串是否全部由掩码字符组成（*、•、●）
    private func isAllMasked(s: String): Bool {
        if (s.size == 0) { return false }
        for (r in s.runes()) {
            if (r != r'*' && r != r'•' && r != r'●') { return false }
        }
        true
    }

    /// 剥离 ANSI 转义序列（简化版，用于密码检测）
    private func stripAnsiEscapes(text: String): String {
        let bytes = text.toArray()
        var result = ArrayList<UInt8>()
        var i: Int64 = 0
        while (i < bytes.size) {
            if (bytes[i] == 27 && i + 1 < bytes.size && bytes[i + 1] == b'[') {
                // ESC[ ... 序列，跳到字母结尾
                i += 2
                while (i < bytes.size && !((bytes[i] >= b'A' && bytes[i] <= b'Z') || (bytes[i] >= b'a' && bytes[i] <= b'z'))) {
                    i += 1
                }
                if (i < bytes.size) { i += 1 }  // 跳过结尾字母
            } else {
                result.add(bytes[i])
                i += 1
            }
        }
        String.fromUtf8(result.toArray())
    }

    private func shouldCallLlm(exited: Bool): Bool {
        let now = monotonicMs()
        if (!dirtyOutput && !exited) { return false }
        if (now < nextEligibleAt && !exited) { return false }
        if (lastDecisionAt > 0 && now - lastDecisionAt < minDecisionIntervalMs && !exited) {
            return false
        }
        if (!exited && lastOutputAt > 0 && now - lastOutputAt < quietWindowMs) {
            if (firstDirtyOutputAt == 0 || now - firstDirtyOutputAt < maxWaitAfterOutputMs) {
                return false
            }
        }
        match (llmBuf) {
            case Some(buf) =>
                if (buf.currentOffset() == buf.sentOffset() && !buf.hasPreview() && !exited) { return false }
            case None => if (!exited) { return false }
        }
        true
    }

    private func nextDelayMs(): Int64 {
        let now = monotonicMs()
        var delay: Int64 = 100
        if (nextEligibleAt > now) {
            let d = nextEligibleAt - now
            if (d > delay) { delay = d }
        }
        if (lastDecisionAt > 0 && now - lastDecisionAt < minDecisionIntervalMs) {
            let d = minDecisionIntervalMs - (now - lastDecisionAt)
            if (d > delay) { delay = d }
        }
        if (lastOutputAt > 0 && now - lastOutputAt < quietWindowMs) {
            let d = quietWindowMs - (now - lastOutputAt)
            if (d > delay) { delay = d }
        }
        if (delay > 1000) { 1000 } else { delay }
    }

    private func callLlmForDecision(): ?PtyTool {
        let now = monotonicMs()

        let req = ChatRequest(config.llm.model)
        req.maxTokens = Some(2048)
        req.tools = Some(ptyToolDefinitions())
        // Some providers (DeepSeek thinking mode) reject tool_choice entirely;
        // omit it so the API defaults to auto — the model still sees the tools.
        // req.toolChoice = Some(ToolChoice.Required)
        req.systemPrompt = Some(buildPtyAgentSystemPrompt(context))

        for (msg in decisionHistory) { req.messages.add(msg) }

        let snapshot = match (llmBuf) {
            case Some(buf) => buf.snapshot()
            case None => PtyLlmContextSnapshot("No compacted history.", "", "", 0, 0, 0)
        }
        req.addUserMessage(buildPtyUserMessage(
            redactSensitive(snapshot.checkpoint),
            redactSensitive(snapshot.recent),
            redactSensitive(snapshot.delta),
            roundCount,
            command))

        let resp = provider.chat(req)
        var toolCall: ?ToolCall = None
        var inputTokens: Int64 = 0
        var outputTokens: Int64 = 0
        if (resp.toolCalls.size > 0) {
            toolCall = Some(resp.toolCalls[0])
        }
        inputTokens = resp.usage.inputTokens
        outputTokens = resp.usage.outputTokens

        lastDecisionAt = now
        dirtyOutput = false
        firstDirtyOutputAt = 0
        match (llmBuf) {
            case Some(buf) => buf.markSent()
            case None => ()
        }
        roundCount += 1
        totalInputTokens += inputTokens
        totalOutputTokens += outputTokens
        ptyDebugLog(
            "LLM usage context=${snapshot.contextBytes} delta=${snapshot.deltaBytes} compact=${snapshot.compactCount} tokens=${inputTokens}+${outputTokens}")

        match (toolCall) {
            case Some(tc) =>
                lastToolCall = Some(tc)
                let tool = parsePtyTool(tc.name, tc.arguments)
                // 构建 assistant 消息（含 tool_use block）
                let assistantMsg = Message()
                assistantMsg.role = MessageRole.Assistant
                assistantMsg.content = ""  // 纯 tool call，无文本
                var tcs = ArrayList<ToolCall>()
                tcs.add(tc)
                assistantMsg.toolCalls = Some(tcs)
                decisionHistory.add(assistantMsg)
                trimDecisionHistory()
                tool
            case None =>
                lastToolCall = None
                let text = resp.content
                let short = truncateRunes(text, 500)
                ptyDebugLog("← LLM text(${text.size}b) finish=${resp.finishReason}: ${short}")
                None
        }
    }

    private func runFinalLlmRound(p: Pty): PtyResult {
        match (callLlmForDecision()) {
            case Some(tool) =>
                match (tool) {
                    case PtyTool.Exit(summary) =>
                        let result = collectResult(p)
                        result.summary = summary
                        return result
                    case _ =>
                        let result = collectResult(p)
                        result.summary = uiText("pty_command_finished")
                        return result
                }
            case None =>
                let result = collectResult(p)
                result.summary = uiText("pty_command_finished")
                return result
        }
    }

    private func collectResult(p: Pty): PtyResult {
        let result = PtyResult()
        result.exitCode = p.getExitCode()
        match (textBuf) {
            case Some(buf) => result.output = buf.toPlainText()
            case None => result.output = ""
        }
        if (result.summary.size == 0) {
            result.summary = uiText("pty_command_finished")
        }
        result
    }

    private func executeTool(p: Pty, tool: PtyTool): Bool {
        match (tool) {
            case PtyTool.Write(content, reason) => executeWrite(p, content, reason)
            case PtyTool.AskUser(question, sensitive) => executeAskUser(question, sensitive)
            case PtyTool.Wait(ms) =>
                executeWait(ms)
                true
            case PtyTool.Exit(summary) => false
            case PtyTool.Interrupt(reason) =>
                loopState = PtyLoopState.Interrupted(reason)
                onEvent(AppEvent.PtyStateChange(loopState))
                false
        }
    }

    private func executeWrite(p: Pty, content: String, reason: String): Bool {
        let modeStr = match (mode) { case PtyMode.FullAuto => "FullAuto"; case PtyMode.Confirm => "Confirm" }
        ptyDebugLog("WRITE mode=${modeStr} reason=${reason} len=${content.size}")
        pushOverlayUpdateWithWrite(content, reason)

        match (mode) {
            case PtyMode.FullAuto =>
                let _ = p.writeData(content + "\n")
                addToolResultToHistory("{\"result\":\"wrote ${content.size} bytes\"}")
                return true
            case _ => () // PtyMode.Confirm
        }

        loopState = PtyLoopState.AwaitingConfirm(content, reason)
        onEvent(AppEvent.PtyStateChange(loopState))

        let action = waitForUserAction()
        if (action == "confirm") {
            let _ = p.writeData(content + "\n")
            addToolResultToHistory("{\"result\":\"user confirmed, wrote ${content.size} bytes\"}")
        } else if (action == "deny") {
            addToolResultToHistory("{\"result\":\"user denied write\"}")
        } else if (action == "full_auto") {
            mode = PtyMode.FullAuto
            let _ = p.writeData(content + "\n")
            addToolResultToHistory("{\"result\":\"switched to full_auto, wrote ${content.size} bytes\"}")
        }
        true
    }

    private func executeAskUser(question: String, sensitive: Bool): Bool {
        ptyDebugLog("ASK_USER question=${question} sensitive=${sensitive}")
        loopState = PtyLoopState.AwaitingUserInput(question, sensitive)
        onEvent(AppEvent.PtyStateChange(loopState))
        pushOverlayUpdateWithAskUser(question, sensitive)

        let action = waitForUserAction()
        if (action.startsWith("user_input:")) {
            let input = action["user_input:".size..]
            let _ = pty.getOrThrow().writeData(input + "\n")
            let displayInput = if (sensitive) { "[REDACTED]" } else { input }
            addToolResultToHistory("{\"result\":\"user provided input\"}")
            if (sensitive) { redactedPatterns.add(input) }
        } else if (action == "interrupt") {
            return false
        }
        true
    }

    private func executeWait(ms: Int64): Unit {
        let clamped = if (ms < 500) { 500 } else if (ms > 30000) { 30000 } else { ms }
        loopState = PtyLoopState.Throttled(clamped)
        onEvent(AppEvent.PtyStateChange(loopState))
        nextEligibleAt = monotonicMs() + clamped
        addToolResultToHistory("{\"result\":\"waited ${clamped}ms\"}")
    }

    // ── Tool result 消息辅助 ──

    /// 添加 tool result 消息到对话历史（含 tool_call_id 关联）
    private func addToolResultToHistory(result: String): Unit {
        let msg = Message()
        msg.role = MessageRole.Tool
        msg.content = result
        match (lastToolCall) {
            case Some(ltc) => msg.toolCallId = Some(ltc.id)
            case None => ()
        }
        decisionHistory.add(msg)
        trimDecisionHistory()
    }

    private func trimDecisionHistory(): Unit {
        let limit = if (decisionHistoryLimit < 2) { 2 } else { decisionHistoryLimit }
        while (decisionHistory.size > limit) {
            decisionHistory.remove(at: 0)
        }
    }

    // ── 同步辅助 ──

    private func waitForUserAction(): String {
        var got = false
        var result = ""
        while (!got) {
            // 等待用户输入的同时也处理 resize 请求
            processResize()

            synchronized(mtx) {
                if (interruptRequested) {
                    interruptRequested = false
                    result = "interrupt"
                    got = true
                }
                if (!got) {
                    match (userAction) {
                        case Some(a) =>
                            userAction = None
                            result = a
                            got = true
                        case None => ()
                    }
                }
            }
            if (!got) { sleepMs(50) }
        }
        let actionStr = if (result.startsWith("user_input:")) { "user_input(len=${result.size})" } else { result }
        ptyDebugLog("user_action: ${actionStr}")
        result
    }

    private func checkInterrupt(): Bool {
        var interrupted = false
        synchronized(mtx) {
            if (interruptRequested) {
                interruptRequested = false
                interrupted = true
            }
        }
        if (interrupted) { ptyDebugLog("INTERRUPT requested") }
        interrupted
    }

    private func processModeSwitch(): Unit {
        synchronized(mtx) {
            match (modeSwitchRequested) {
                case Some(newMode) => mode = newMode; modeSwitchRequested = None
                case None => ()
            }
        }
    }

    private func processResize(): Unit {
        var size: ?(UInt16, UInt16) = None
        synchronized(mtx) {
            match (resizeRequested) {
                case Some(s) => size = Some(s); resizeRequested = None
                case None => ()
            }
        }
        match (size) {
            case Some((cols, rows)) =>
                match (pty) {
                    case Some(p) => p.resize(rows, cols)
                    case None => ()
                }
                match (textBuf) {
                    case Some(buf) =>
                        ptyDebugLog("resize: ${rows}x${cols} buf_size=${buf.size()}")
                    case None => ()
                }
            case None => ()
        }
    }

    // ── 浮层面板更新 ──

    private func pushOverlayUpdate(): Unit {
        let data = PtyOverlayData()
        data.mode = mode
        data.roundCount = roundCount
        data.maxRounds = maxRounds
        data.tokenInput = totalInputTokens
        data.tokenOutput = totalOutputTokens
        onEvent(AppEvent.PtyOverlayUpdate(data))
    }

    private func pushOverlayUpdateWithWrite(content: String, reason: String): Unit {
        let data = PtyOverlayData()
        data.mode = mode
        data.llmDecision = Some("Write")
        data.pendingWrite = Some(content)
        data.pendingReason = Some(reason)
        data.roundCount = roundCount
        data.maxRounds = maxRounds
        data.tokenInput = totalInputTokens
        data.tokenOutput = totalOutputTokens
        onEvent(AppEvent.PtyOverlayUpdate(data))
    }

    private func pushOverlayUpdateWithAskUser(question: String, sensitive: Bool): Unit {
        let data = PtyOverlayData()
        data.mode = mode
        data.llmDecision = Some(if (sensitive) { "AskUser (sensitive)" } else { "AskUser" })
        data.pendingWrite = Some(question)
        data.pendingReason = None
        data.roundCount = roundCount
        data.maxRounds = maxRounds
        data.tokenInput = totalInputTokens
        data.tokenOutput = totalOutputTokens
        onEvent(AppEvent.PtyOverlayUpdate(data))
    }

    // ── 敏感内容脱敏 ──

    private func redactSensitive(text: String): String {
        var result = text
        for (pattern in redactedPatterns) {
            result = replaceAll(result, pattern, "[PASSWORD_REDACTED]")
        }
        result
    }

    private func replaceAll(text: String, from: String, to: String): String {
        if (from.size == 0) { return text }
        let textBytes = text.toArray()
        let fromBytes = from.toArray()
        var result = ArrayList<UInt8>()
        var i: Int64 = 0
        while (i <= textBytes.size - fromBytes.size) {
            var matched = true
            for (j in 0..fromBytes.size) {
                if (textBytes[i + j] != fromBytes[j]) { matched = false; break }
            }
            if (matched) {
                for (b in to.toArray()) { result.add(b) }
                i += fromBytes.size
            } else {
                result.add(textBytes[i])
                i += 1
            }
        }
        while (i < textBytes.size) { result.add(textBytes[i]); i += 1 }
        String.fromUtf8(result.toArray())
    }
}

// ── 公开辅助函数 ──

func buildPtyUserMessage(checkpoint: String, recent: String, delta: String, round: Int64, command: String): String {
    """
The command being executed is: ${command}

Round: ${round}

Terminal checkpoint:
---
${checkpoint}
---

Recent terminal output after compaction:
---
${recent}
---

New normalized output since your previous decision:
---
${delta}
---

Choose the next action based on the terminal output above. The output is normalized: carriage-return and ANSI progress bars are compressed to their latest visible state.
- If the program is prompting for input, use Write to provide it.
- If you need information from the user (password, choice), use AskUser.
- If the output is still updating, use Wait.
- If the command has finished, use Exit with a summary.
- If something is wrong (unexpected prompt, error, stuck), use Interrupt.
"""
}

func parsePtyTool(name: String, argsJson: String): ?PtyTool {
    if (name == "Write") {
        Some(PtyTool.Write(extractJsonString(argsJson, "content"), extractJsonString(argsJson, "reason")))
    } else if (name == "AskUser") {
        Some(PtyTool.AskUser(extractJsonString(argsJson, "question"), extractJsonBool(argsJson, "sensitive")))
    } else if (name == "Wait") {
        Some(PtyTool.Wait(extractJsonInt(argsJson, "milliseconds")))
    } else if (name == "Exit") {
        Some(PtyTool.Exit(extractJsonString(argsJson, "summary")))
    } else if (name == "Interrupt") {
        Some(PtyTool.Interrupt(extractJsonString(argsJson, "reason")))
    } else {
        None
    }
}

/// 返回 PtyTool 的可读名称（debug 用）
func toolToolName(tool: PtyTool): String {
    match (tool) {
        case PtyTool.Write(_, _) => "Write"
        case PtyTool.AskUser(_, _) => "AskUser"
        case PtyTool.Wait(_) => "Wait"
        case PtyTool.Exit(_) => "Exit"
        case PtyTool.Interrupt(_) => "Interrupt"
    }
}

func extractJsonString(json: String, key: String): String {
    let pattern = "\"${key}\""
    var idx = findSubstring(json, pattern)
    if (idx < 0) { return "" }

    idx = idx + pattern.size
    var startQuote: Int64 = -1
    for (i in idx..json.size) {
        if (json[i] == b'"') { startQuote = Int64(i); break }
    }
    if (startQuote < 0) { return "" }

    var endQuote: Int64 = -1
    for (i in (startQuote + 1)..json.size) {
        if (json[i] == b'"' && (i == 0 || json[i - 1] != b'\\')) {
            endQuote = Int64(i); break
        }
    }
    if (endQuote < 0) { return "" }

    var resultBytes = ArrayList<UInt8>()
    for (i in (startQuote + 1)..endQuote) {
        resultBytes.add(json[i])
    }
    unescapeJson(String.fromUtf8(resultBytes.toArray()))
}

func extractJsonBool(json: String, key: String): Bool {
    let s = extractJsonString(json, key)
    if (s.size == 0) {
        let pattern = "\"${key}\""
        let idx = findSubstring(json, pattern)
        if (idx < 0) { return false }
        let tail = substringFrom(json, idx + pattern.size)
        for (ch in tail.runes()) {
            if (ch == r't') { return true }
            if (ch == r'f') { return false }
        }
        return false
    }
    s == "true"
}

func extractJsonInt(json: String, key: String): Int64 {
    let s = extractJsonString(json, key)
    if (s.size == 0) {
        let pattern = "\"${key}\""
        let idx = findSubstring(json, pattern)
        if (idx < 0) { return 1000 }
        let tail = substringFrom(json, idx + pattern.size)
        var numStr = ""
        var started = false
        for (ch in tail.runes()) {
            if ((ch >= r'0' && ch <= r'9') || ch == r'-') {
                numStr += String(ch); started = true
            } else if (started) { break }
        }
        if (numStr.size > 0) { return parseJsonInt64(numStr) }
        return 1000
    }
    parseJsonInt64(s)
}

func findSubstring(text: String, pattern: String): Int64 {
    if (pattern.size == 0) { return 0 }
    if (pattern.size > text.size) { return -1 }
    for (i in 0..(text.size - pattern.size + 1)) {
        var matched = true
        for (j in 0..pattern.size) {
            if (text[i + j] != pattern[j]) { matched = false; break }
        }
        if (matched) { return i }
    }
    -1
}

func substringFrom(text: String, start: Int64): String {
    if (start >= text.size) { return "" }
    let bytes = text.toArray()
    var resultBytes = ArrayList<UInt8>()
    for (i in start..bytes.size) { resultBytes.add(bytes[i]) }
    String.fromUtf8(resultBytes.toArray())
}

func unescapeJson(text: String): String {
    let bytes = text.toArray()
    var result = ArrayList<UInt8>()
    var i: Int64 = 0
    while (i < bytes.size) {
        if (bytes[i] == b'\\' && i + 1 < bytes.size) {
            let next = bytes[i + 1]
            if (next == b'n') { result.add(b'\n') }
            else if (next == b't') { result.add(b'\t') }
            else if (next == b'r') { result.add(b'\r') }
            else if (next == b'"') { result.add(b'"') }
            else if (next == b'\\') { result.add(b'\\') }
            else { result.add(next) }
            i += 2
        } else {
            result.add(bytes[i])
            i += 1
        }
    }
    String.fromUtf8(result.toArray())
}

/// 简易整数解析（本地实现，避免跨包引用）
func parseJsonInt64(s: String): Int64 {
    var result: Int64 = 0
    let bytes = s.toArray()
    for (b in bytes) {
        if (b >= b'0' && b <= b'9') { result = result * 10 + Int64(b - b'0') }
    }
    result
}

/// 获取单调时钟毫秒时间戳（CLOCK_MONOTONIC，不受系统时间调整影响）
func monotonicMs(): Int64 {
    unsafe {
        let tsPtr = LibC.malloc<Timespec>(count: 1)
        tsPtr.write(0, Timespec(0, 0))
        clock_gettime(CLOCK_MONOTONIC, tsPtr)
        let ts = tsPtr.read(0)
        LibC.free(tsPtr)
        Int64(ts.tv_sec) * 1000 + Int64(ts.tv_nsec) / 1000000
    }
}

/// 毫秒级休眠
func sleepMs(ms: Int64): Unit {
    unsafe {
        usleep(UInt64(ms) * 1000)
    }
}
