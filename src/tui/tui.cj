package termhelper.tui

import ratatui.core.*
import termhelper.types.*
import termhelper.core.*
import termhelper.infra.*
import termhelper.i18n.*
import termhelper.tui.screens.*
import termhelper.tui.components.*
import termhelper.adapters.*
import std.collection.*
import std.sync.*

public class AppEventQueue {
    private let mtx: Mutex
    private let events: ArrayList<AppEvent>

    public init() {
        this.mtx = Mutex()
        this.events = ArrayList<AppEvent>()
    }

    public func push(event: AppEvent): Unit {
        synchronized(mtx) {
            events.add(event)
        }
    }

    public func tryPop(): ?AppEvent {
        synchronized(mtx) {
            if (events.size == 0) {
                None
            } else {
                let event = events[0]
                events.remove(at: 0)
                Some(event)
            }
        }
    }
}

class TuiAppState {
    let queue: AppEventQueue
    var screen: String
    var promptMode: String
    var query: String
    var lastRequest: String
    var loadingText: String
    var retryText: String
    var tick: Int64
    var selected: Int64
    var currentCommand: ?CommandData
    var investigate: ?InvestigateData
    var clarify: ?ClarifyData
    var input: String
    var errorMessage: String
    var retryable: Bool
    var shouldExit: Bool
    var activeSpawn: ?SpawnHandle
    var executeCommand: String
    var executeLines: ArrayList<String>
    var executeDone: Bool
    var executeResult: ?CommandResult
    var widgetHandle: ?Int64
    var lastRenderedContent: String
    var lastSpinnerFrame: Int64
    var lastRenderedScrollOffset: Int64
    var scrollOffset: Int64
    var maxScrollOffset: Int64
    var viewportHeight: Int64
    var terminalWidth: Int64
    var terminalHeight: Int64
    // PTY agentic 状态（阶段 6）
    var ptyCommand: String
    var ptyOutput: String
    var ptyOverlay: PtyOverlayData
    var ptyState: String
    var ptyTokenInput: Int64
    var ptyTokenOutput: Int64
    var ptyInput: String
    var ptySensitiveInput: Bool
    var ptyAgent: ?PtyAgentLoop
    var ptyTerminalBuf: ?TerminalBuffer  // TUI 侧虚拟终端缓冲区（ANSI Cell→Span 渲染用）

    init(query: String) {
        this.queue = AppEventQueue()
        this.screen = "loading"
        this.promptMode = ""
        this.query = query
        this.lastRequest = query
        this.loadingText = ""
        this.retryText = ""
        this.tick = 0
        this.selected = 0
        this.currentCommand = None
        this.investigate = None
        this.clarify = None
        this.input = ""
        this.errorMessage = ""
        this.retryable = false
        this.shouldExit = false
        this.activeSpawn = None
        this.executeCommand = ""
        this.executeLines = ArrayList<String>()
        this.executeDone = false
        this.executeResult = None
        this.widgetHandle = None
        this.lastRenderedContent = ""
        this.lastSpinnerFrame = -1
        this.lastRenderedScrollOffset = -1
        this.scrollOffset = 0
        this.maxScrollOffset = 0
        this.viewportHeight = 20
        this.terminalWidth = 80
        this.terminalHeight = 24
        this.ptyCommand = ""
        this.ptyOutput = ""
        this.ptyOverlay = PtyOverlayData()
        this.ptyState = "waiting"
        this.ptyTokenInput = 0
        this.ptyTokenOutput = 0
        this.ptyInput = ""
        this.ptySensitiveInput = false
        this.ptyAgent = None
        this.ptyTerminalBuf = None
    }
}

/// 初始化 TUI，进入 alternate screen + raw mode
public func initTUI(): Result<Int64, RatatuiException> {
    initTerminal()
}

/// 阶段 5 主流程入口。
public func runApp(query: String, session: Session, config: Config): Result<Unit, RatatuiException> {
    match (initTUI()) {
        case Ok(terminal) =>
            let state = TuiAppState(query)
            startLlmTask(state.queue, session, query, false)
            let loopResult = runLoop(terminal, state, session, config)
            let _ = cleanupTUI(terminal)
            loopResult
        case Err(e) => Result.Err(e)
    }
}

/// 兼容阶段 1 占位调用。
public func runMainLoop(terminal: Int64): Result<Unit, RatatuiException> {
    var running = true
    while (running) {
        match (pollEvent(100)) {
            case Some(eventHandle) =>
                if (eventIsQuit(eventHandle) || eventGetKeyCode(eventHandle) == 27) {
                    running = false
                }
                eventFree(eventHandle)
            case None => ()
        }
        let _ = drawTerminal(terminal)
    }
    Result.Ok(())
}

public func runStyleDemo(): Result<Unit, RatatuiException> {
    match (initTUI()) {
        case Ok(terminal) =>
            renderStyleDemo(terminal)
            var running = true
            while (running) {
                match (pollEvent(100)) {
                    case Some(eventHandle) =>
                        let code = eventGetKeyCode(eventHandle)
                        if (eventIsQuit(eventHandle) || code == 27 || code == 13 || code == 10) {
                            running = false
                        }
                        eventFree(eventHandle)
                    case None => ()
                }
            }
            let _ = cleanupTUI(terminal)
            Result.Ok(())
        case Err(e) => Result.Err(e)
    }
}

/// 清理 TUI，恢复终端模式
public func cleanupTUI(terminal: Int64): Result<Unit, RatatuiException> {
    cleanupTerminal(terminal)
}

func runLoop(terminal: Int64, state: TuiAppState, session: Session, config: Config): Result<Unit, RatatuiException> {
    while (!state.shouldExit) {
        drainEvents(state, session)
        pollExecute(state)

        match (pollEvent(50)) {
            case Some(eventHandle) =>
                match (mapEvent(eventHandle)) {
                    case Some(action) => handleAction(state, session, config, action)
                    case None => ()
                }
                eventFree(eventHandle)
            case None => ()
        }

        state.tick = state.tick + 1
        render(terminal, state)
    }
    cleanupActiveSpawn(state)
    Result.Ok(())
}

func startLlmTask(queue: AppEventQueue, session: Session, text: String, modify: Bool): Unit {
    spawn {
        => try {
            let response = if (modify) {
                session.modify(text)
            } else {
                session.start(text)
            }
            queue.push(AppEvent.LLMDone(response))
        } catch (e: Exception) {
            queue.push(AppEvent.LLMError(e.message))
        }
    }
}

func drainEvents(state: TuiAppState, session: Session): Unit {
    var keepGoing = true
    while (keepGoing) {
        match (state.queue.tryPop()) {
            case Some(event) => handleAppEvent(state, session, event)
            case None => keepGoing = false
        }
    }
}

func handleAppEvent(state: TuiAppState, session: Session, event: AppEvent): Unit {
    match (event) {
        case AppEvent.LLMChunk(text) => state.loadingText += text
        case AppEvent.LLMRetrying(attempt, reason) => state.retryText = uiRetryStatus(attempt, reason)
        case AppEvent.LLMDone(response) => match (session.handleResponse(response)) {
            case SessionAction.ShowCommand(data) =>
                state.currentCommand = Some(data)
                state.selected = 0
                switchScreen(state, "result")
            case SessionAction.RequestInvestigate(data) =>
                state.investigate = Some(data)
                state.promptMode = "investigate"
                state.selected = 0
                switchScreen(state, "prompt")
            case SessionAction.AskClarify(data) =>
                state.clarify = Some(data)
                state.promptMode = "clarify"
                state.input = ""
                switchScreen(state, "prompt")
            case SessionAction.FormatError(message) => showError(state, message, false)
            case SessionAction.ProviderError(message) => showError(state, message, true)
        }
        case AppEvent.LLMError(message) => showError(state, message, true)
        case AppEvent.PtyScreenUpdate(text) =>
            match (state.ptyTerminalBuf) {
                case Some(buf) => buf.processString(text)
                case None => ()
            }
            // 同时保留纯文本用于降级渲染
            match (state.ptyTerminalBuf) {
                case Some(buf) => state.ptyOutput = buf.toPlainText()
                case None => state.ptyOutput = text
            }
        case AppEvent.PtyStateChange(loopState) =>
            handlePtyStateChange(state, loopState)
        case AppEvent.PtyOverlayUpdate(data) =>
            state.ptyOverlay = data
            state.ptyTokenInput = data.tokenInput
            state.ptyTokenOutput = data.tokenOutput
        case AppEvent.SignalReceived(sig) =>
            cleanupActiveSpawn(state)
            state.shouldExit = true
        case _ => ()
    }
}

func handleAction(state: TuiAppState, session: Session, config: Config, action: Action): Unit {
    match (action) {
        case Action.TerminalResize(w, h) =>
            handleResize(state, Int64(w), Int64(h))
            return
        case _ => ()
    }
    if (handleScrollAction(state, action)) {
        return
    }

    match (state.screen) {
        case "loading" => handleLoadingAction(state, action)
        case "result" => handleResultAction(state, config, action)
        case "execute" => handleExecuteAction(state, action)
        case "prompt" => handlePromptAction(state, session, config, action)
        case "error" => handleErrorAction(state, session, action)
        case "pty" => handlePtyAction(state, action)
        case _ => ()
    }
}

func handleScrollAction(state: TuiAppState, action: Action): Bool {
    match (action) {
        case Action.ScrollUp =>
            scrollBy(state, -1)
            true
        case Action.ScrollDown =>
            scrollBy(state, 1)
            true
        case Action.PageUp =>
            scrollBy(state, -pageScrollAmount(state))
            true
        case Action.PageDown =>
            scrollBy(state, pageScrollAmount(state))
            true
        case Action.ScrollTop =>
            state.scrollOffset = 0
            true
        case Action.ScrollBottom =>
            state.scrollOffset = state.maxScrollOffset
            true
        case _ => false
    }
}

func scrollBy(state: TuiAppState, delta: Int64): Unit {
    let next = state.scrollOffset + delta
    if (next < 0) {
        state.scrollOffset = 0
    } else if (next > state.maxScrollOffset) {
        state.scrollOffset = state.maxScrollOffset
    } else {
        state.scrollOffset = next
    }
}

func pageScrollAmount(state: TuiAppState): Int64 {
    if (state.viewportHeight > 4) {
        state.viewportHeight - 4
    } else {
        1
    }
}

func switchScreen(state: TuiAppState, screen: String): Unit {
    if (state.screen != screen) {
        state.scrollOffset = 0
        state.maxScrollOffset = 0
        state.lastRenderedScrollOffset = -1
    }
    state.screen = screen
}

func handleLoadingAction(state: TuiAppState, action: Action): Unit {
    match (action) {
        case Action.Back | Action.Interrupt => state.shouldExit = true
        case _ => ()
    }
}

func handleResultAction(state: TuiAppState, config: Config, action: Action): Unit {
    let data = match (state.currentCommand) {
        case Some(d) => d
        case None => return
    }
    let menu = resultMenu(data.interactive)
    match (action) {
        case Action.NavigateUp =>
            if (state.selected > 0) {
                state.selected = state.selected - 1
            }
        case Action.NavigateDown =>
            if (state.selected + 1 < menu.size) {
                state.selected = state.selected + 1
            }
        case Action.Run =>
            if (!data.interactive) {
                startExecute(state, data.command, config)
            }
        case Action.Copy => copyCommandOrShowError(state, data.command)
        case Action.Modify => openModify(state, data.command)
        case Action.Confirm =>
            let item = menu[state.selected]
            if (item.key == "run") {
                startExecute(state, data.command, config)
            } else if (item.key == "run_pty") {
                startPtyAgentic(state, data.command, config)
            } else if (item.key == "copy") {
                copyCommandOrShowError(state, data.command)
            } else if (item.key == "modify") {
                openModify(state, data.command)
            } else {
                state.shouldExit = true
            }
        case Action.Back | Action.Interrupt => state.shouldExit = true
        case _ => ()
    }
}

func handleExecuteAction(state: TuiAppState, action: Action): Unit {
    match (action) {
        case Action.Confirm =>
            if (state.executeDone) {
                state.shouldExit = true
            }
        case Action.Interrupt =>
            if (state.executeDone) {
                state.shouldExit = true
            } else {
                match (state.activeSpawn) {
                    case Some(handle) => handle.interrupt()
                    case None => ()
                }
            }
        case Action.Back =>
            if (state.executeDone) {
                state.shouldExit = true
            } else {
                match (state.activeSpawn) {
                    case Some(handle) => handle.interrupt()
                    case None => ()
                }
                switchScreen(state, "result")
            }
        case _ => ()
    }
}

func handlePromptAction(state: TuiAppState, session: Session, config: Config, action: Action): Unit {
    if (state.promptMode == "investigate") {
        handleInvestigateAction(state, session, config, action)
    } else {
        handleTextPromptAction(state, session, action)
    }
}

func handleInvestigateAction(state: TuiAppState, session: Session, config: Config, action: Action): Unit {
    let data = match (state.investigate) {
        case Some(d) => d
        case None => return
    }
    match (action) {
        case Action.NavigateUp =>
            if (state.selected > 0) {
                state.selected = state.selected - 1
            }
        case Action.NavigateDown =>
            if (state.selected + 1 < data.commands.size) {
                state.selected = state.selected + 1
            }
        case Action.Toggle =>
            if (data.commands.size > 0) {
                data.commands[state.selected].authorized = !data.commands[state.selected].authorized
            }
        case Action.Run => for (cmd in data.commands) {
            cmd.authorized = true
        }
        case Action.Confirm =>
            switchScreen(state, "loading")
            state.loadingText = uiText("running_diagnostics") + "\n"
            state.retryText = ""
            runInvestigationTask(state.queue, session, data, config.execution.spawnTimeoutSec)
        case Action.Back | Action.Interrupt => state.shouldExit = true
        case _ => ()
    }
}

func handleTextPromptAction(state: TuiAppState, session: Session, action: Action): Unit {
    match (action) {
        case Action.TextInput(text) => state.input += text
        case Action.Run => state.input += "r"
        case Action.Copy => state.input += "c"
        case Action.Modify => state.input += "m"
        case Action.Toggle => state.input += " "
        case Action.Backspace =>
            if (state.input.size > 0) {
                state.input = removeLastRune(state.input)
            }
        case Action.Confirm | Action.Submit =>
            if (state.input.trimAscii().size > 0) {
                let submitted = state.input
                state.lastRequest = submitted
                switchScreen(state, "loading")
                state.loadingText = ""
                state.retryText = ""
                state.input = ""
                startLlmTask(state.queue, session, submitted, true)
            }
        case Action.Back | Action.Interrupt => switchScreen(state, "result")
        case _ => ()
    }
}

func handleErrorAction(state: TuiAppState, session: Session, action: Action): Unit {
    match (action) {
        case Action.Confirm | Action.Run =>
            if (state.retryable) {
                switchScreen(state, "loading")
                state.loadingText = ""
                state.retryText = ""
                startLlmTask(state.queue, session, state.lastRequest, true)
            }
        case Action.Back | Action.Interrupt => state.shouldExit = true
        case _ => ()
    }
}

// ── 终端 resize 处理 ──

func handleResize(state: TuiAppState, width: Int64, height: Int64): Unit {
    state.terminalWidth = width
    state.terminalHeight = height
    state.scrollOffset = 0
    state.maxScrollOffset = 0
    state.lastRenderedScrollOffset = -1

    // PTY 屏幕：更新 PTY 终端大小 + 重建虚拟终端缓冲区
    if (state.screen == "pty") {
        let cols = if (width > 10) { width } else { 80 }
        let rows = if (height > 5) { height - 5 } else { 20 }  // 减去 overlay 行数

        // 通知 agent 更新 PTY slave 窗口大小
        match (state.ptyAgent) {
            case Some(agent) => agent.requestResize(UInt16(cols), UInt16(rows))
            case None => ()
        }

        // 重建 TUI 侧虚拟终端缓冲区（新尺寸）
        match (state.ptyTerminalBuf) {
            case Some(buf) => buf.resize(rows, cols)
            case None => state.ptyTerminalBuf = Some(TerminalBuffer(rows, cols))
        }
    }
}

// ── PTY Agentic（阶段 6）──

func handlePtyStateChange(state: TuiAppState, loopState: PtyLoopState): Unit {
    match (loopState) {
        case PtyLoopState.WaitingOutput => state.ptyState = "waiting"
        case PtyLoopState.LLMDecision => state.ptyState = "llm_decision"
        case PtyLoopState.AwaitingConfirm(content, reason) =>
            state.ptyState = "awaiting_confirm"
        case PtyLoopState.AwaitingUserInput(question, sensitive) =>
            state.ptyState = "awaiting_input"
            state.ptySensitiveInput = sensitive
        case PtyLoopState.Finished(result) =>
            state.ptyState = "finished"
            state.ptyOutput = result.output
        case PtyLoopState.Interrupted(reason) =>
            state.ptyState = "interrupted"
        case PtyLoopState.Throttled(ms) =>
            state.ptyState = "throttled"
        case PtyLoopState.RoundLimitReached =>
            state.ptyState = "round_limit"
    }
}

func startPtyAgentic(state: TuiAppState, command: String, config: Config): Unit {
    state.ptyCommand = command
    state.ptyOutput = ""
    state.ptyOverlay = PtyOverlayData()
    state.ptyOverlay.maxRounds = config.execution.ptyMaxRounds
    state.ptyState = "waiting"
    state.ptyTokenInput = 0
    state.ptyTokenOutput = 0
    state.ptyInput = ""
    state.ptySensitiveInput = false
    state.scrollOffset = 0
    state.maxScrollOffset = 0
    switchScreen(state, "pty")

    // 获取真实终端大小（来自 infra 层）
    let (cols, rows) = getHostTerminalSize()
    state.terminalWidth = Int64(cols)
    state.terminalHeight = Int64(rows)
    debugTrace("startPtyAgentic: terminal_size=${rows}x${cols}")
    // 创建 TUI 侧虚拟终端缓冲区（用于 Cell→Span ANSI 渲染）
    state.ptyTerminalBuf = Some(TerminalBuffer(Int64(rows), Int64(cols)))

    // 在后台启动 PtyAgentLoop
    let queue = state.queue
    let ptyCmd = command
    spawn {
        => try {
            let ctxManager = ContextManager()
            let ctx = ctxManager.load()
            let provider = createPtyProvider(config)
            let agent = PtyAgentLoop({e: AppEvent => queue.push(e)}, provider, config, ctx)
            state.ptyAgent = Some(agent)
            debugTrace("startPtyAgentic: running agent for command=${ptyCmd}")
            let result = agent.run(ptyCmd, rows, cols)
            debugTrace("startPtyAgentic: agent finished exitCode=${result.exitCode}")
            state.ptyOutput = result.output
            let finalOverlay = PtyOverlayData()
            finalOverlay.mode = agent.getMode()
            finalOverlay.roundCount = agent.getRound()
            finalOverlay.maxRounds = config.execution.ptyMaxRounds
            queue.push(AppEvent.PtyOverlayUpdate(finalOverlay))
        } catch (e: Exception) {
            debugTrace("startPtyAgentic: exception=${e.message}")
            queue.push(AppEvent.PtyStateChange(PtyLoopState.Interrupted(e.message)))
        }
    }
}

func createPtyProvider(config: Config): LLMProvider {
    let baseUrl = config.llm.baseUrl
    let connectSec = config.llm.connectTimeoutSec
    let readSec = config.llm.timeoutSec
    let idleSec = config.llm.idleTimeoutSec
    if (config.provider == "anthropic") {
        LLMProvider.fromAnthropic(
            AnthropicProvider(baseUrl, config.llm.apiKey, config.llm.model, connectSec, readSec, idleSec))
    } else if (config.provider == "google") {
        LLMProvider.fromGoogle(GoogleProvider(baseUrl, config.llm.apiKey, config.llm.model, connectSec, readSec, idleSec))
    } else {
        LLMProvider.fromOpenAI(
            OpenAICompatProvider(baseUrl, config.llm.apiKey, config.llm.model, connectSec, readSec, idleSec))
    }
}

func handlePtyAction(state: TuiAppState, action: Action): Unit {
    match (state.ptyState) {
        case "awaiting_confirm" => handlePtyConfirmAction(state, action)
        case "awaiting_input" => handlePtyInputAction(state, action)
        case "round_limit" => handlePtyRoundLimitAction(state, action)
        case "finished" | "interrupted" => handlePtyDoneAction(state, action)
        case _ => handlePtyDefaultAction(state, action)
    }
}

func handlePtyDefaultAction(state: TuiAppState, action: Action): Unit {
    match (action) {
        case Action.Back | Action.Interrupt =>
            match (state.ptyAgent) {
                case Some(agent) => agent.requestInterrupt()
                case None => ()
            }
            state.shouldExit = true
        case Action.ScrollUp =>
            if (state.scrollOffset > 0) { state.scrollOffset -= 1 }
        case Action.ScrollDown =>
            state.scrollOffset += 1
            if (state.maxScrollOffset > 0 && state.scrollOffset > state.maxScrollOffset) {
                state.scrollOffset = state.maxScrollOffset
            }
        case Action.PageUp =>
            state.scrollOffset -= 15
            if (state.scrollOffset < 0) { state.scrollOffset = 0 }
        case Action.PageDown =>
            state.scrollOffset += 15
        // Toggle full auto mode with 'A' key
        case Action.TextInput(text) =>
            if (text.size == 1) {
                let ch = text[0]
                if (ch == b'A' || ch == b'a') {
                    match (state.ptyAgent) {
                        case Some(agent) =>
                            let newMode = match (state.ptyOverlay.mode) {
                                case PtyMode.FullAuto => PtyMode.Confirm
                                case PtyMode.Confirm => PtyMode.FullAuto
                            }
                            agent.switchMode(newMode)
                            state.ptyOverlay.mode = newMode
                        case None => ()
                    }
                }
            }
        case _ => ()
    }
}

func handlePtyConfirmAction(state: TuiAppState, action: Action): Unit {
    match (action) {
        case Action.Confirm =>
            // 确认写入
            match (state.ptyAgent) {
                case Some(agent) => agent.submitUserAction("confirm")
                case None => ()
            }
            state.ptyState = "waiting"
        case Action.Back | Action.Interrupt =>
            // 中断
            match (state.ptyAgent) {
                case Some(agent) =>
                    agent.submitUserAction("interrupt")
                    agent.requestInterrupt()
                case None => ()
            }
            state.shouldExit = true
        case Action.TextInput(text) =>
            if (text.size == 1) {
                let ch = text[0]
                if (ch == b'D' || ch == b'd') {
                    // 拒绝写入
                    match (state.ptyAgent) {
                        case Some(agent) => agent.submitUserAction("deny")
                        case None => ()
                    }
                    state.ptyState = "waiting"
                } else if (ch == b'A' || ch == b'a') {
                    // 切换全自动并确认
                    match (state.ptyAgent) {
                        case Some(agent) =>
                            agent.switchMode(PtyMode.FullAuto)
                            agent.submitUserAction("full_auto")
                            state.ptyOverlay.mode = PtyMode.FullAuto
                        case None => ()
                    }
                    state.ptyState = "waiting"
                }
            }
        case _ => ()
    }
}

func handlePtyInputAction(state: TuiAppState, action: Action): Unit {
    match (action) {
        case Action.Confirm | Action.Submit =>
            if (state.ptyInput.size > 0) {
                let input = state.ptyInput
                match (state.ptyAgent) {
                    case Some(agent) => agent.submitUserAction("user_input:${input}")
                    case None => ()
                }
                state.ptyInput = ""
                state.ptyState = "waiting"
            }
        case Action.Back | Action.Interrupt =>
            match (state.ptyAgent) {
                case Some(agent) =>
                    agent.submitUserAction("interrupt")
                    agent.requestInterrupt()
                case None => ()
            }
            state.shouldExit = true
        case Action.TextInput(text) =>
            state.ptyInput += text
        case Action.Run => state.ptyInput += "r"
        case Action.Copy => state.ptyInput += "c"
        case Action.Modify => state.ptyInput += "m"
        case Action.Toggle => state.ptyInput += " "
        case Action.Backspace =>
            if (state.ptyInput.size > 0) {
                state.ptyInput = state.ptyInput[0..(state.ptyInput.size - 1)]
            }
        case _ => ()
    }
}

func handlePtyRoundLimitAction(state: TuiAppState, action: Action): Unit {
    match (action) {
        case Action.Confirm =>
            match (state.ptyAgent) {
                case Some(agent) => agent.submitUserAction("continue")
                case None => ()
            }
            state.ptyState = "waiting"
        case Action.Back | Action.Interrupt =>
            match (state.ptyAgent) {
                case Some(agent) => agent.submitUserAction("interrupt")
                case None => ()
            }
            state.shouldExit = true
        case Action.TextInput(text) =>
            if (text.size == 1) {
                let ch = text[0]
                if (ch == b'I' || ch == b'i') {
                    match (state.ptyAgent) {
                        case Some(agent) => agent.submitUserAction("interrupt")
                        case None => ()
                    }
                    state.shouldExit = true
                } else if (ch == b'M' || ch == b'm') {
                    match (state.ptyAgent) {
                        case Some(agent) => agent.submitUserAction("manual")
                        case None => ()
                    }
                    state.shouldExit = true
                }
            }
        case _ => ()
    }
}

func handlePtyDoneAction(state: TuiAppState, action: Action): Unit {
    match (action) {
        case Action.Confirm | Action.Back | Action.Interrupt =>
            state.shouldExit = true
        case _ => ()
    }
}

func startExecute(state: TuiAppState, command: String, config: Config): Unit {
    state.executeCommand = command
    state.executeLines = ArrayList<String>()
    state.executeDone = false
    state.executeResult = None
    state.activeSpawn = Some(spawnAsync(command, config.execution.spawnTimeoutSec * 1000))
    switchScreen(state, "execute")
}

func pollExecute(state: TuiAppState): Unit {
    let handle = match (state.activeSpawn) {
        case Some(h) => h
        case None => return
    }
    var reading = true
    while (reading) {
        match (handle.tryReadLine()) {
            case Some(line) =>
                if (line.isStderr) {
                    state.executeLines.add("stderr: " + line.text)
                } else {
                    state.executeLines.add(line.text)
                }
            case None => reading = false
        }
    }
    if (!state.executeDone && handle.isDone()) {
        let result = handle.waitDone()
        state.executeResult = Some(result)
        state.executeDone = true
        state.activeSpawn = None
    }
}

func cleanupActiveSpawn(state: TuiAppState): Unit {
    match (state.activeSpawn) {
        case Some(handle) => handle.interrupt()
        case None => ()
    }
    match (state.ptyAgent) {
        case Some(agent) => agent.requestInterrupt()
        case None => ()
    }
}

func runInvestigationTask(queue: AppEventQueue, session: Session, data: InvestigateData, timeoutSec: Int64): Unit {
    spawn {
        => try {
            let outputs = ArrayList<String>()
            let executedCommands = ArrayList<String>()
            for (cmd in data.commands) {
                if (cmd.authorized) {
                    let result = spawnCommandWithTimeout(cmd.command, timeoutSec * 1000)
                    executedCommands.add(cmd.command)
                    var entry = "$ ${cmd.command}\n"
                    entry += "exit=${result.exitCode}\n"
                    if (result.stdout.size > 0) {
                        entry += "stdout:\n${result.stdout}\n"
                    }
                    if (result.stderr.size > 0) {
                        entry += "stderr:\n${result.stderr}\n"
                    }
                    outputs.add(entry)
                }
            }
            session.setInvestigationSources(executedCommands)
            let response = session.modify(investigationSummary(data, outputs))
            queue.push(AppEvent.LLMDone(response))
        } catch (e: Exception) {
            queue.push(AppEvent.LLMError(e.message))
        }
    }
}

func copyCommandOrShowError(state: TuiAppState, command: String): Unit {
    match (copyToClipboard(command)) {
        case ClipResult.Ok => state.shouldExit = true
        case ClipResult.Unsupported(reason) => showError(state, uiClipboardError(reason, clipboardInstallHint(), command),
            false)
    }
}

func openModify(state: TuiAppState, command: String): Unit {
    state.promptMode = "modify"
    state.input = ""
    state.loadingText = ""
    switchScreen(state, "prompt")
    state.errorMessage = uiModifyPrompt(command)
}

func showError(state: TuiAppState, message: String, retryable: Bool): Unit {
    state.errorMessage = message
    state.retryable = retryable
    switchScreen(state, "error")
}

func updateScrollBounds(terminal: Int64, state: TuiAppState, content: String): Unit {
    let terminalHeight = Int64(getTerminalHeight(terminal))
    state.viewportHeight = if (terminalHeight > 2) {
        terminalHeight - 1
    } else {
        20
    }

    let lineCount = countLines(content)
    state.maxScrollOffset = if (lineCount > state.viewportHeight) {
        lineCount - state.viewportHeight
    } else {
        0
    }

    if (state.scrollOffset > state.maxScrollOffset) {
        state.scrollOffset = state.maxScrollOffset
    }
    if (state.scrollOffset < 0) {
        state.scrollOffset = 0
    }
}

func countLines(content: String): Int64 {
    if (content.size == 0) {
        return 0
    }

    var count: Int64 = 1
    for (b in content) {
        if (b == b'\n') {
            count += 1
        }
    }
    count
}

func scrollOffsetToUInt16(offset: Int64): UInt16 {
    if (offset <= 0) {
        0
    } else if (offset > 65535) {
        65535
    } else {
        UInt16(offset)
    }
}

func render(terminal: Int64, state: TuiAppState): Unit {
    let spinnerFrame = state.tick / 4
    let content = buildScreenText(state, spinnerFrame)
    updateScrollBounds(terminal, state, content)
    if (content == state.lastRenderedContent && spinnerFrame == state.lastSpinnerFrame && state.scrollOffset == state
        .lastRenderedScrollOffset) {
        return
    }

    state.lastRenderedContent = content
    state.lastSpinnerFrame = spinnerFrame
    state.lastRenderedScrollOffset = state.scrollOffset

    // The terminal owns widget handles after addWidgetToTerminal() in this SDK.
    // Do not manually free handles that have been attached to the terminal.
    let _ = clearTerminalWidgets(terminal)
    state.widgetHandle = None

    // PTY 屏幕使用多 widget 布局（终端内容 + 固定底部 overlay）
    if (state.screen == "pty") {
        renderPtyMultiWidget(terminal, state, spinnerFrame)
    } else {
        match (createBlockWidget(screenTitle(state))) {
            case Ok(handle) =>
                let _ = setWidgetPosition(handle, 0, 0)
                let _ = setWidgetSize(handle, 0, 0)
                let _ = addWidgetToTerminal(terminal, handle)
            case Err(_) => ()
        }
        if (!renderStyledContent(terminal, state, spinnerFrame)) {
            match (createTextWidget(content)) {
                case Ok(handle) =>
                    state.widgetHandle = Some(handle)
                    let _ = setWidgetPosition(handle, 2, 1)
                    let _ = setWidgetSize(handle, 0, 0)
                    let _ = setWidgetScroll(handle, scrollOffsetToUInt16(state.scrollOffset), 0)
                    let _ = addWidgetToTerminal(terminal, handle)
                case Err(_) => ()
            }
        }
    }
    let _ = drawTerminal(terminal)
}

/// PTY 多 widget 布局：顶部标题栏 + 中间终端内容 + 底部 overlay Block
func renderPtyMultiWidget(terminal: Int64, state: TuiAppState, spinnerFrame: Int64): Unit {
    let termHeight = state.terminalHeight
    let termWidth = state.terminalWidth
    let overlayRows: Int64 = 5   // 底部 overlay 固定行数
    let contentHeight: Int64 = if (termHeight > overlayRows + 2) {
        termHeight - overlayRows - 2
    } else {
        10
    }

    // 1. 标题栏 (Block widget, 行 0)
    match (createBlockWidget(screenTitle(state))) {
        case Ok(handle) =>
            let _ = setWidgetPosition(handle, 0, 0)
            let _ = setWidgetSize(handle, UInt16(termWidth), 0)
            let _ = addWidgetToTerminal(terminal, handle)
        case Err(_) => ()
    }

    // 2. 终端内容区域 (StyledText, 行 1, 高度 = contentHeight)
    match (createRichTextWidget()) {
        case Ok(handle) =>
            // 渲染终端 Cell 内容到此 widget
            fillPtyTerminalWidget(handle, state)
            let _ = setWidgetPosition(handle, 0, 1)
            let _ = setWidgetSize(handle, UInt16(termWidth), UInt16(contentHeight))
            let _ = setWidgetScroll(handle, scrollOffsetToUInt16(state.scrollOffset), 0)
            let _ = addWidgetToTerminal(terminal, handle)
            state.widgetHandle = Some(handle)
        case Err(_) => ()
    }

    // 3. 底部 overlay 面板 (Block widget + StyledText 叠加, 行 = 1 + contentHeight)
    let overlayY = 1 + contentHeight
    match (createRichTextWidget()) {
        case Ok(handle) =>
            fillPtyOverlayWidget(handle, state)
            let _ = setWidgetPosition(handle, 0, UInt16(overlayY))
            let _ = setWidgetSize(handle, UInt16(termWidth), UInt16(overlayRows))
            let _ = addWidgetToTerminal(terminal, handle)
        case Err(_) => ()
    }
}

/// 将终端 Cell 内容填充到 widget（仅终端输出，不含 overlay）
func fillPtyTerminalWidget(handle: Int64, state: TuiAppState): Unit {
    match (state.ptyTerminalBuf) {
        case Some(buf) =>
            let overlayRows: Int64 = 5
            let titleRows: Int64 = 2
            let vr = state.terminalHeight - overlayRows - titleRows
            let visibleRows = if (vr > 4) { vr } else { 4 }
            renderTerminalCells(handle, buf, state.scrollOffset, state.maxScrollOffset, visibleRows)
        case None => richTextLine(handle, "  " + uiText("pty_waiting_output"), styleMuted())
    }
}

/// 将 overlay 面板内容填充到 widget
func fillPtyOverlayWidget(handle: Int64, state: TuiAppState): Unit {
    let data = state.ptyOverlay
    let ptyState = state.ptyState

    // 面板标题（带边框效果的 Block 标题行）
    richTextLine(handle, "── " + uiText("pty_overlay_title") + " ──", styleSection())

    let modeLabel = match (data.mode) {
        case PtyMode.FullAuto => uiText("pty_full_auto")
        case PtyMode.Confirm => uiText("pty_confirm")
    }
    let statusLabel = ptyStatusText(ptyState)
    var infoLine = "  ${uiText("overlay_mode")}: ${modeLabel}"
    infoLine += "  ${uiText("overlay_round")}: ${data.roundCount}/${data.maxRounds}"
    infoLine += "  ${uiText("pty_tokens_used")}: ${data.tokenInput}+${data.tokenOutput}"
    infoLine += "  [${statusLabel}]"
    richTextLine(handle, infoLine, styleMuted())

    // LLM 决策信息
    match (data.llmDecision) {
        case Some(d) =>
            richTextSpan(handle, "  ${uiText("overlay_decision")}: ", styleMuted())
            richTextLine(handle, d, styleInfo())
        case None => ()
    }
    match (data.pendingWrite) {
        case Some(content) =>
            richTextSpan(handle, "  ${uiText("overlay_pending_write")}: ", styleMuted())
            let short = if (content.size > 60) { content[0..60] + "..." } else { content }
            richTextLine(handle, short, styleCommand())
        case None => ()
    }

    // 交互按钮提示
    if (ptyState == "awaiting_confirm") {
        richTextSpan(handle, "  [Enter]${uiText("pty_confirm_write")} ", styleSuccess())
        richTextSpan(handle, "[D]${uiText("pty_deny")} ", styleErrorText())
        richTextSpan(handle, "[A]${uiText("pty_switch_auto")}", styleInfo())
    } else if (ptyState == "round_limit") {
        richTextSpan(handle, "  [Enter]${uiText("pty_continue")} ", styleSuccess())
        richTextSpan(handle, "[I]${uiText("pty_interrupt")} ", styleErrorText())
        richTextSpan(handle, "[M]${uiText("pty_manual")}", styleInfo())
    }
}

func ptyStatusText(ptyState: String): String {
    match (ptyState) {
        case "waiting" => uiText("pty_status_waiting")
        case "llm_decision" => uiText("pty_status_llm_decision")
        case "awaiting_confirm" => uiText("pty_status_awaiting_confirm")
        case "awaiting_input" => uiText("pty_status_awaiting_input")
        case "throttled" => uiText("pty_status_throttled")
        case "round_limit" => uiText("pty_status_round_limit")
        case "finished" => uiText("pty_status_finished")
        case "interrupted" => uiText("pty_status_interrupted")
        case _ => ptyState
    }
}

func renderStyledContent(terminal: Int64, state: TuiAppState, spinnerFrame: Int64): Bool {
    match (createRichTextWidget()) {
        case Ok(handle) =>
            state.widgetHandle = Some(handle)
            buildStyledScreen(handle, state, spinnerFrame)
            let _ = setWidgetPosition(handle, 2, 1)
            let _ = setWidgetSize(handle, 0, 0)
            let _ = setWidgetScroll(handle, scrollOffsetToUInt16(state.scrollOffset), 0)
            let _ = addWidgetToTerminal(terminal, handle)
            true
        case Err(_) => false
    }
}

func buildStyledScreen(handle: Int64, state: TuiAppState, spinnerFrame: Int64): Unit {
    match (state.screen) {
        case "loading" => styledLoading(handle, state.query, spinnerFrame, state.loadingText, state.retryText)
        case "result" => match (state.currentCommand) {
            case Some(data) => styledResult(handle, data, state.selected)
            case None => styledError(handle, uiText("error_no_command"), false)
        }
        case "execute" => styledExecute(handle, state.executeCommand, state.executeLines, state.executeDone,
            state.executeResult)
        case "prompt" => styledPrompt(handle, state)
        case "error" => styledError(handle, state.errorMessage, state.retryable)
        case "pty" => styledPtyAgentic(handle, state.ptyCommand, state.ptyTerminalBuf, state.ptyOverlay,
            state.ptyState, state.scrollOffset, state.maxScrollOffset,
            state.ptyInput, state.ptySensitiveInput)
        case _ => richTextLine(handle, uiText("app_title"), styleTitle())
    }
}

func styledLoading(handle: Int64, query: String, frame: Int64, streamedText: String, retryText: String): Unit {
    richTextSpan(handle, uiText("loading_title"), styleTitle())
    richTextSpan(handle, "  " + spinnerFrame(frame), styleInfo())
    richTextLine(handle)
    richTextLine(handle)
    styledSection(handle, uiText("section_query"))
    styledWrapped(handle, "  " + query, UI_WIDTH - 2, "  ", styleDefault())
    if (retryText.size > 0) {
        richTextLine(handle)
        styledSection(handle, uiText("section_retry"))
        styledWrapped(handle, "  " + retryText, UI_WIDTH - 2, "  ", styleWarning())
    }
    richTextLine(handle)
    styledSection(handle, uiText("section_model_response"))
    if (streamedText.size == 0) {
        richTextLine(handle, "  " + uiText("waiting_model"), styleMuted())
    } else {
        styledWrapped(handle, streamedText, UI_WIDTH, "", styleDefault())
    }
    styledKeys(handle, uiText("keys_exit"))
}

func styledResult(handle: Int64, data: CommandData, selected: Int64): Unit {
    richTextSpan(handle, uiText("result_title"), styleTitle())
    richTextSpan(handle, "  " + if (data.interactive) {
        uiText("mode_interactive")
    } else {
        uiText("mode_runnable")
    }, if (data.interactive) {
        styleWarning()
    } else {
        styleSuccess()
    })
    richTextLine(handle)
    richTextLine(handle)
    styledSection(handle, uiText("section_command"))
    richTextSpan(handle, "  $ ", styleMuted())
    richTextLine(handle, data.command, styleCommand())
    if (data.explanation.summary.size > 0) {
        styledField(handle, uiText("field_summary"), data.explanation.summary, styleDefault())
    }
    richTextLine(handle)
    styledSection(handle, uiText("section_breakdown"))
    if (data.explanation.breakdown.size == 0) {
        richTextLine(handle, "  " + uiText("no_breakdown"), styleMuted())
    } else {
        for (item in data.explanation.breakdown) {
            styledBreakdownItem(handle, item.component, item.explanation)
        }
    }
    richTextLine(handle)
    styledSection(handle, uiText("section_safety"))
    richTextLine(handle, "  " + safetyMarker(data.safety.level) + " " + safetyLabel(data.safety.level),
        styleSafety(data.safety.level))
    if (data.safety.warnings.size == 0) {
        richTextLine(handle, "  " + uiText("no_safety_warnings"), styleMuted())
    } else {
        for (warning in data.safety.warnings) {
            styledWrapped(handle, "  * " + warning, UI_WIDTH - 4, "    ", styleWarning())
        }
    }
    richTextLine(handle)
    styledOptionMenu(handle, resultMenu(data.interactive), selected)
    styledKeys(handle, uiText("keys_result"))
}

func styledExecute(handle: Int64, command: String, lines: ArrayList<String>, done: Bool, result: ?CommandResult): Unit {
    richTextSpan(handle, uiText("execute_title"), styleTitle())
    richTextSpan(handle, "  " + if (done) {
        uiText("status_done")
    } else {
        uiText("status_running")
    }, if (done) {
        styleSuccess()
    } else {
        styleInfo()
    })
    richTextLine(handle)
    richTextLine(handle)
    styledSection(handle, uiText("section_command"))
    richTextSpan(handle, "  $ ", styleMuted())
    richTextLine(handle, command, styleCommand())
    richTextLine(handle)
    styledSection(handle, uiText("section_result"))
    styledField(handle, uiText("field_status"), if (done) {
        uiText("status_done")
    } else {
        uiText("status_running")
    }, if (done) {
        styleSuccess()
    } else {
        styleInfo()
    })
    match (result) {
        case Some(r) => styledField(handle, uiText("field_exit_code"), "${r.exitCode}", if (r.exitCode == 0) {
            styleSuccess()
        } else {
            styleErrorText()
        })
        case None => ()
    }
    richTextLine(handle)
    styledSection(handle, uiText("section_output"))
    let start = if (lines.size > 14) {
        lines.size - 14
    } else {
        0
    }
    for (i in start..lines.size) {
        let isErr = lines[i].startsWith("stderr: ")
        let displayLine = if (isErr) {
            lines[i][8..]
        } else {
            lines[i]
        }
        let lineStyle = if (isErr) {
            styleErrorText()
        } else {
            styleDefault()
        }
        styledWrapped(handle, "  " + displayLine, UI_WIDTH - 2, "  ", lineStyle)
    }
    if (lines.size == 0) {
        richTextLine(handle, "  " + uiText("no_output"), styleMuted())
    }
    styledKeys(handle, if (done) {
        uiText("keys_execute_done")
    } else {
        uiText("keys_execute_running")
    })
}

func styledPrompt(handle: Int64, state: TuiAppState): Unit {
    if (state.promptMode == "investigate") {
        match (state.investigate) {
            case Some(data) => styledInvestigate(handle, data, state.selected)
            case None => styledError(handle, uiText("error_no_investigation"), false)
        }
    } else if (state.promptMode == "clarify") {
        match (state.clarify) {
            case Some(data) => styledTextPrompt(handle, uiText("prompt_clarify"), data.question, state.input, false)
            case None => styledError(handle, uiText("error_no_clarify"), false)
        }
    } else {
        styledTextPrompt(handle, uiText("prompt_modify"), state.errorMessage, state.input, false)
    }
}

func styledInvestigate(handle: Int64, data: InvestigateData, selected: Int64): Unit {
    richTextSpan(handle, uiText("investigate_title"), styleTitle())
    richTextSpan(handle, "  " + uiCountChecks(data.commands.size), styleWarning())
    richTextLine(handle)
    richTextLine(handle)
    styledSection(handle, uiText("section_reason"))
    styledWrapped(handle, "  " + data.reason, UI_WIDTH - 2, "  ", styleDefault())
    richTextLine(handle)
    styledSection(handle, uiText("section_diagnostic_commands"))
    for (i in 0..data.commands.size) {
        let cmd = data.commands[i]
        let cursor = if (i == selected) {
            "  > "
        } else {
            "    "
        }
        let mark = if (cmd.authorized) {
            "[x] "
        } else {
            "[ ] "
        }
        richTextLine(handle, cursor + mark + cmd.command, if (i == selected) {
            styleSelected()
        } else {
            styleCommand()
        })
        styledWrapped(handle, "      " + cmd.rationale, UI_WIDTH - 6, "      ", styleMuted())
    }
    styledKeys(handle, uiText("keys_investigate"))
}

func styledTextPrompt(handle: Int64, title: String, question: String, current: String, sensitive: Bool): Unit {
    richTextSpan(handle, title, styleTitle())
    richTextSpan(handle, "  " + uiText("waiting_input"), styleInfo())
    richTextLine(handle)
    if (question.size > 0) {
        richTextLine(handle)
        styledSection(handle, uiText("section_prompt"))
        styledWrapped(handle, question, UI_WIDTH, "", styleDefault())
    }
    richTextLine(handle)
    styledSection(handle, uiText("section_input"))
    styledInputBox(handle, if (sensitive) {
        maskedInput(current)
    } else {
        current
    })
    styledKeys(handle, uiText("keys_submit_cancel"))
}

func styledInputBox(handle: Int64, value: String): Unit {
    let width = UI_WIDTH - 4
    richTextLine(handle, "  ┌" + repeatText("─", width) + "┐", styleMuted())
    let contentWidth = width - 3
    let lines = inputBoxLines(value, contentWidth)
    for (i in 0..lines.size) {
        let line = lines[i]
        let isLast = i + 1 == lines.size
        richTextSpan(handle, "  │ ", styleMuted())
        richTextSpan(handle, line, styleInput())
        if (isLast) {
            richTextSpan(handle, " ", styleInputCursor())
            richTextSpan(handle, repeatText(" ", contentWidth - displayWidth(line)), styleInput())
        } else {
            richTextSpan(handle, repeatText(" ", contentWidth + 1 - displayWidth(line)), styleInput())
        }
        richTextLine(handle, " │", styleMuted())
    }
    richTextLine(handle, "  └" + repeatText("─", width) + "┘", styleMuted())
}

func inputBoxLines(value: String, width: Int64): ArrayList<String> {
    let lines = ArrayList<String>()
    if (value.size == 0) {
        lines.add("")
        return lines
    }

    for (raw in value.split("\n")) {
        appendWrappedInputLine(lines, raw, width)
    }
    if (lines.size == 0) {
        lines.add("")
    }
    lines
}

func appendWrappedInputLine(lines: ArrayList<String>, raw: String, width: Int64): Unit {
    if (raw.size == 0) {
        lines.add("")
        return
    }

    var line = ""
    var lineWidth: Int64 = 0
    for (r in raw.runes()) {
        let piece = String(r)
        let pieceWidth = displayWidth(piece)
        if (lineWidth > 0 && lineWidth + pieceWidth > width) {
            lines.add(line)
            line = piece
            lineWidth = pieceWidth
        } else {
            line += piece
            lineWidth += pieceWidth
        }
    }
    lines.add(line)
}

func removeLastRune(value: String): String {
    let runes = value.toRuneArray()
    if (runes.size <= 1) {
        return ""
    }

    var result = ""
    for (i in 0..(runes.size - 1)) {
        result += String(runes[i])
    }
    result
}

func maskedInput(current: String): String {
    var out = ""
    for (_ in current.runes()) {
        out += "*"
    }
    out
}

func styledError(handle: Int64, message: String, retryable: Bool): Unit {
    richTextSpan(handle, uiText("error_title"), styleErrorText())
    if (retryable) {
        richTextSpan(handle, "  " + uiText("retryable"), styleWarning())
    }
    richTextLine(handle)
    richTextLine(handle)
    styledWrapped(handle, message, UI_WIDTH, "", styleDefault())
    if (retryable) {
        richTextLine(handle)
        styledSection(handle, uiText("section_recovery"))
        richTextLine(handle, "  " + uiText("retry_hint"), styleMuted())
    }
    styledKeys(handle, uiText("keys_exit"))
}

func styledOptionMenu(handle: Int64, items: ArrayList<MenuItem>, selected: Int64): Unit {
    styledSection(handle, uiText("section_actions"))
    for (i in 0..items.size) {
        let prefix = if (i == selected) {
            "  > "
        } else {
            "    "
        }
        richTextLine(handle, prefix + items[i].label, if (i == selected) {
            styleSelected()
        } else {
            styleDefault()
        })
    }
}

func styledSection(handle: Int64, title: String): Unit {
    richTextLine(handle, title, styleSection())
}

func styledField(handle: Int64, label: String, value: String, valueStyle: RichStyle): Unit {
    let sep = if (isChinese()) {
        "："
    } else {
        ": "
    }
    richTextSpan(handle, "  " + label + sep, styleMuted())
    richTextLine(handle, value, valueStyle)
}

func styledBreakdownItem(handle: Int64, component: String, explanation: String): Unit {
    richTextSpan(handle, "  ", styleDefault())
    richTextSpan(handle, component, styleBodyStrong())
    richTextSpan(handle, ": ", styleMuted())
    richTextLine(handle, explanation, styleDefault())
}

func styledWrapped(handle: Int64, text: String, width: Int64, indent: String, lineStyle: RichStyle): Unit {
    for (raw in text.split("\n")) {
        let wrapped = wrapLine(raw, width, indent)
        for (line in wrapped.split("\n")) {
            richTextLine(handle, line, lineStyle)
        }
    }
}

func styledKeys(handle: Int64, keys: String): Unit {
    richTextLine(handle)
    richTextSpan(handle, keys, styleMuted())
}

func styleSafety(level: SafetyLevel): RichStyle {
    match (level) {
        case SafetyLevel.Safe => styleSuccess()
        case SafetyLevel.Caution => styleWarning()
        case SafetyLevel.Danger => styleDanger()
        case SafetyLevel.Privilege => styleErrorText()
    }
}

func renderStyleDemo(terminal: Int64): Unit {
    let _ = clearTerminalWidgets(terminal)
    match (createBlockWidget(uiText("style_demo_title"))) {
        case Ok(handle) =>
            let _ = setWidgetPosition(handle, 0, 0)
            let _ = setWidgetSize(handle, 0, 0)
            let _ = addWidgetToTerminal(terminal, handle)
        case Err(_) => ()
    }

    match (createRichTextWidget()) {
        case Ok(handle) =>
            richTextSpan(handle, uiText("result_title"), styleTitle())
            richTextSpan(handle, "  " + uiText("mode_runnable"), styleSuccess())
            richTextLine(handle)
            richTextLine(handle)

            richTextLine(handle, uiText("section_query"), styleSection())
            richTextLine(handle, uiText("style_demo_query"), styleDefault())
            richTextLine(handle)

            richTextLine(handle, uiText("section_command"), styleSection())
            richTextSpan(handle, "  $ ", styleMuted())
            richTextLine(handle, uiText("style_demo_command"), styleCommand())
            richTextLine(handle, uiText("style_demo_summary"), styleDefault())
            richTextLine(handle)

            richTextLine(handle, uiText("section_safety"), styleSection())
            richTextSpan(handle, "  [+] " + uiText("safety_safe"), styleSuccess())
            richTextLine(handle, uiText("style_demo_warning"), styleMuted())
            richTextLine(handle)

            richTextLine(handle, uiText("section_actions"), styleSection())
            richTextLine(handle, "  > " + uiText("menu_run"), styleSelected())
            richTextLine(handle, "    " + uiText("menu_copy"), styleDefault())
            richTextLine(handle, "    " + uiText("menu_modify"), styleDefault())
            richTextLine(handle)

            richTextSpan(handle, uiText("keys_result"), styleMuted())
            let _ = setWidgetPosition(handle, 2, 1)
            let _ = setWidgetSize(handle, 0, 0)
            let _ = addWidgetToTerminal(terminal, handle)
        case Err(_) => ()
    }
    let _ = drawTerminal(terminal)
}

func screenTitle(state: TuiAppState): String {
    match (state.screen) {
        case "loading" => uiText("screen_thinking")
        case "result" => uiText("screen_result")
        case "execute" => uiText("screen_execute")
        case "prompt" =>
            if (state.promptMode == "investigate") {
                uiText("screen_investigate")
            } else if (state.promptMode == "clarify") {
                uiText("screen_clarify")
            } else {
                uiText("screen_modify")
            }
        case "error" => uiText("screen_error")
        case "pty" => uiText("screen_pty")
        case _ => uiText("app_title")
    }
}

func buildScreenText(state: TuiAppState, renderTick: Int64): String {
    match (state.screen) {
        case "loading" => renderLoading(state.query, renderTick, state.loadingText, state.retryText)
        case "result" => match (state.currentCommand) {
            case Some(data) => renderResult(data, state.selected)
            case None => renderError(uiText("error_no_command"), false)
        }
        case "execute" => renderExecute(state.executeCommand, state.executeLines, state.executeDone, state.executeResult)
        case "prompt" => buildPromptText(state)
        case "error" => renderError(state.errorMessage, state.retryable)
        case "pty" => renderPtyAgentic(state.ptyCommand, state.ptyOutput, state.ptyOverlay,
            state.ptyState, state.scrollOffset,
            state.ptyInput, state.ptySensitiveInput)
        case _ => uiText("app_title") + "\n"
    }
}

func buildPromptText(state: TuiAppState): String {
    if (state.promptMode == "investigate") {
        match (state.investigate) {
            case Some(data) => renderInvestigate(data, state.selected)
            case None => renderError(uiText("error_no_investigation"), false)
        }
    } else if (state.promptMode == "clarify") {
        match (state.clarify) {
            case Some(data) => renderTextPrompt(uiText("prompt_clarify"), data.question, state.input, false)
            case None => renderError(uiText("error_no_clarify"), false)
        }
    } else {
        renderTextPrompt(uiText("prompt_modify"), state.errorMessage, state.input, false)
    }
}
