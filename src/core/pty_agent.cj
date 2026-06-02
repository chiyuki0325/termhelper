package termhelper.core

import termhelper.types.*
import termhelper.adapters.*
import termhelper.infra.*
import termhelper.i18n.*
import termhelper.util.*
import std.collection.*
import std.sync.*

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
    private var terminalBuf: ?TerminalBuffer
    private var command: String

    // ── 循环状态 ──
    private var roundCount: Int64
    private var maxRounds: Int64
    private var mode: PtyMode
    private var loopState: PtyLoopState
    private var totalInputTokens: Int64
    private var totalOutputTokens: Int64

    // ── 节流 ──
    private var lastLlmCallTime: Int64
    private var lastOutputSize: Int64
    private var minIntervalMs: Int64
    private var minBytesThreshold: Int64

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

    // ── LLM 对话历史（仅 PTY agent 上下文）──
    private var decisionHistory: ArrayList<Message>

    // ── 敏感内容脱敏 ──
    private var redactedPatterns: ArrayList<String>

    public init(onEvent: (AppEvent) -> Unit, provider: LLMProvider, config: Config, context: EnvironmentContext) {
        this.pty = None
        this.terminalBuf = None
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
        this.lastLlmCallTime = 0
        this.lastOutputSize = 0
        this.minIntervalMs = config.execution.ptyMinIntervalMs
        this.minBytesThreshold = config.execution.ptyMinBytesThreshold
        this.onEvent = onEvent
        this.provider = provider
        this.config = config
        this.context = context
        this.mtx = Mutex()
        this.userAction = None
        this.interruptRequested = false
        this.modeSwitchRequested = None
        this.decisionHistory = ArrayList<Message>()
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

        // 1. 创建 PTY 和虚拟终端缓冲区
        match (Pty.create(terminalRows, terminalCols)) {
            case Some(p) => this.pty = Some(p)
            case None =>
                let result = PtyResult()
                result.exitCode = -1
                result.summary = uiText("pty_create_failed")
                onEvent(AppEvent.PtyStateChange(PtyLoopState.Finished(result)))
                return result
        }
        let p = pty.getOrThrow()
        this.terminalBuf = Some(TerminalBuffer(Int64(terminalRows), Int64(terminalCols)))

        // 2. Spawn 交互式命令
        if (!p.spawnChild(command)) {
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

            let exited = p.childExited()
            let hasOutput = readAndProcessOutput(p)

            if (exited && !hasOutput) {
                if (roundCount > 0) {
                    result = runFinalLlmRound(p)
                } else {
                    result = collectResult(p)
                }
                loopState = PtyLoopState.Finished(result)
                onEvent(AppEvent.PtyStateChange(loopState))
                running = false
                continue
            }

            if (shouldThrottle()) {
                loopState = PtyLoopState.Throttled(minIntervalMs)
                onEvent(AppEvent.PtyStateChange(loopState))
                sleepMs(200)
                continue
            }

            loopState = PtyLoopState.LLMDecision
            onEvent(AppEvent.PtyStateChange(loopState))

            match (callLlmForDecision()) {
                case Some(tool) =>
                    if (!executeTool(p, tool)) {
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
        result
    }

    // ── 内部方法 ──

    private func readAndProcessOutput(p: Pty): Bool {
        let data = p.tryRead(65536)
        if (data.size == 0) { return false }

        // 先发送原始输出给 TUI（含 ANSI 转义序列，供 Cell→Span 渲染）
        onEvent(AppEvent.PtyScreenUpdate(data))

        // 再更新本地 TerminalBuffer（供 LLM 上下文 + 节流用）
        match (terminalBuf) {
            case Some(buf) => buf.processString(data)
            case None => ()
        }
        true
    }

    private func shouldThrottle(): Bool {
        let now = monotonicMs()

        if (lastLlmCallTime > 0 && now - lastLlmCallTime < minIntervalMs) {
            return true
        }

        if (lastLlmCallTime > 0) {
            match (terminalBuf) {
                case Some(buf) =>
                    let currentSize = buf.toPlainText().size
                    if (currentSize - lastOutputSize < minBytesThreshold) { return true }
                case None => ()
            }
        }
        false
    }

    private func callLlmForDecision(): ?PtyTool {
        let now = monotonicMs()

        let req = ChatRequest(config.llm.model)
        req.maxTokens = Some(2048)
        req.tools = Some(ptyToolDefinitions())
        req.toolChoice = Some(ToolChoice.Required)
        req.systemPrompt = Some(buildPtyAgentSystemPrompt(context))

        for (msg in decisionHistory) { req.messages.add(msg) }

        let currentOutput = match (terminalBuf) {
            case Some(buf) => redactSensitive(buf.toPlainText())
            case None => ""
        }
        req.addUserMessage(buildPtyUserMessage(currentOutput, roundCount, command))

        let resp = provider.chat(req)
        var toolCall: ?ToolCall = None
        var inputTokens: Int64 = 0
        var outputTokens: Int64 = 0
        if (resp.toolCalls.size > 0) {
            toolCall = Some(resp.toolCalls[0])
        }
        inputTokens = resp.usage.inputTokens
        outputTokens = resp.usage.outputTokens

        lastLlmCallTime = now
        match (terminalBuf) {
            case Some(buf) => lastOutputSize = buf.toPlainText().size
            case None => ()
        }
        roundCount += 1
        totalInputTokens += inputTokens
        totalOutputTokens += outputTokens

        match (toolCall) {
            case Some(tc) =>
                let tool = parsePtyTool(tc.name, tc.arguments)
                let assistantMsg = makeMessage(MessageRole.Assistant,
                    "{\"tool\":\"${tc.name}\",\"arguments\":${tc.arguments}}")
                decisionHistory.add(assistantMsg)
                tool
            case None => None
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
        match (terminalBuf) {
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
        pushOverlayUpdateWithWrite(content, reason)

        match (mode) {
            case PtyMode.FullAuto =>
                let _ = p.writeData(content + "\n")
                let toolMsg = makeMessage(MessageRole.Tool,
                    "{\"result\":\"wrote ${content.size} bytes\"}")
                decisionHistory.add(toolMsg)
                return true
            case _ => () // PtyMode.Confirm
        }

        loopState = PtyLoopState.AwaitingConfirm(content, reason)
        onEvent(AppEvent.PtyStateChange(loopState))

        let action = waitForUserAction()
        if (action == "confirm") {
            let _ = p.writeData(content + "\n")
            decisionHistory.add(makeMessage(MessageRole.Tool,
                "{\"result\":\"user confirmed, wrote ${content.size} bytes\"}"))
        } else if (action == "deny") {
            decisionHistory.add(makeMessage(MessageRole.Tool,
                "{\"result\":\"user denied write\"}"))
        } else if (action == "full_auto") {
            mode = PtyMode.FullAuto
            let _ = p.writeData(content + "\n")
            decisionHistory.add(makeMessage(MessageRole.Tool,
                "{\"result\":\"switched to full_auto, wrote ${content.size} bytes\"}"))
        }
        true
    }

    private func executeAskUser(question: String, sensitive: Bool): Bool {
        loopState = PtyLoopState.AwaitingUserInput(question, sensitive)
        onEvent(AppEvent.PtyStateChange(loopState))
        pushOverlayUpdateWithAskUser(question, sensitive)

        let action = waitForUserAction()
        if (action.startsWith("user_input:")) {
            let input = action["user_input:".size..]
            let _ = pty.getOrThrow().writeData(input + "\n")
            let displayInput = if (sensitive) { "[REDACTED]" } else { input }
            decisionHistory.add(makeMessage(MessageRole.Tool,
                "{\"result\":\"user provided input\"}"))
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
        sleepMs(clamped)
        decisionHistory.add(makeMessage(MessageRole.Tool,
            "{\"result\":\"waited ${clamped}ms\"}"))
    }

    // ── 同步辅助 ──

    private func waitForUserAction(): String {
        var got = false
        var result = ""
        while (!got) {
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
        var result = ""
        var i: Int64 = 0
        while (i <= text.size - from.size) {
            var matched = true
            for (j in 0..from.size) {
                if (text[i + j] != from[j]) { matched = false; break }
            }
            if (matched) {
                result += to
                i += from.size
            } else {
                result += String(Rune(Int32(text[i])))
                i += 1
            }
        }
        while (i < text.size) {
            result += String(Rune(Int32(text[i])))
            i += 1
        }
        result
    }
}

// ── 公开辅助函数 ──

func buildPtyUserMessage(terminalOutput: String, round: Int64, command: String): String {
    """
Current terminal output (round ${round}):
---
${terminalOutput}
---

The command being executed is: ${command}

Choose the next action based on the terminal output above.
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

    var result = ""
    for (i in (startQuote + 1)..endQuote) {
        result += String(Rune(Int32(json[i])))
    }
    unescapeJson(result)
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
    var result = ""
    for (i in start..text.size) { result += String(Rune(Int32(text[i]))) }
    result
}

func unescapeJson(text: String): String {
    var result = ""
    var i: Int64 = 0
    while (i < text.size) {
        if (text[i] == b'\\' && i + 1 < text.size) {
            let next = text[i + 1]
            if (next == b'n') { result += "\n" }
            else if (next == b't') { result += "\t" }
            else if (next == b'r') { result += "\r" }
            else if (next == b'"') { result += "\"" }
            else if (next == b'\\') { result += "\\" }
            else { result += String(Rune(Int32(next))) }
            i += 2
        } else {
            result += String(Rune(Int32(text[i])))
            i += 1
        }
    }
    result
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

