package termhelper.tui

import ratatui.core.*
import termhelper.types.*
import termhelper.core.*
import termhelper.infra.*
import termhelper.tui.screens.*
import termhelper.tui.components.*
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
    spawn { =>
        try {
            let response = if (modify) { session.modify(text) } else { session.start(text) }
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
            case Some(event) =>
                handleAppEvent(state, session, event)
            case None =>
                keepGoing = false
        }
    }
}

func handleAppEvent(state: TuiAppState, session: Session, event: AppEvent): Unit {
    match (event) {
        case AppEvent.LLMChunk(text) =>
            state.loadingText += text
        case AppEvent.LLMRetrying(attempt, reason) =>
            state.retryText = "attempt ${attempt}: ${reason}"
        case AppEvent.LLMDone(response) =>
            match (session.handleResponse(response)) {
                case SessionAction.ShowCommand(data) =>
                    state.currentCommand = Some(data)
                    state.selected = 0
                    state.screen = "result"
                case SessionAction.RequestInvestigate(data) =>
                    state.investigate = Some(data)
                    state.promptMode = "investigate"
                    state.selected = 0
                    state.screen = "prompt"
                case SessionAction.AskClarify(data) =>
                    state.clarify = Some(data)
                    state.promptMode = "clarify"
                    state.input = ""
                    state.screen = "prompt"
                case SessionAction.FormatError(message) =>
                    showError(state, message, false)
                case SessionAction.ProviderError(message) =>
                    showError(state, message, true)
            }
        case AppEvent.LLMError(message) =>
            showError(state, message, true)
        case _ => ()
    }
}

func handleAction(state: TuiAppState, session: Session, config: Config, action: Action): Unit {
    match (state.screen) {
        case "loading" => handleLoadingAction(state, action)
        case "result" => handleResultAction(state, config, action)
        case "execute" => handleExecuteAction(state, action)
        case "prompt" => handlePromptAction(state, session, config, action)
        case "error" => handleErrorAction(state, session, action)
        case _ => ()
    }
}

func handleLoadingAction(state: TuiAppState, action: Action): Unit {
    match (action) {
        case Action.Back | Action.Interrupt =>
            state.shouldExit = true
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
            if (state.selected > 0) { state.selected = state.selected - 1 }
        case Action.NavigateDown =>
            if (state.selected + 1 < menu.size) { state.selected = state.selected + 1 }
        case Action.Run =>
            if (!data.interactive) { startExecute(state, data.command, config) }
        case Action.Copy =>
            copyCommandOrShowError(state, data.command)
        case Action.Modify =>
            openModify(state, data.command)
        case Action.Confirm =>
            let item = menu[state.selected]
            if (item.key == "run") {
                startExecute(state, data.command, config)
            } else if (item.key == "copy") {
                copyCommandOrShowError(state, data.command)
            } else if (item.key == "modify") {
                openModify(state, data.command)
            } else {
                state.shouldExit = true
            }
        case Action.Back | Action.Interrupt =>
            state.shouldExit = true
        case _ => ()
    }
}

func handleExecuteAction(state: TuiAppState, action: Action): Unit {
    match (action) {
        case Action.Interrupt =>
            match (state.activeSpawn) {
                case Some(handle) => handle.interrupt()
                case None => ()
            }
        case Action.Back =>
            if (state.executeDone) {
                state.screen = "result"
            } else {
                match (state.activeSpawn) {
                    case Some(handle) => handle.interrupt()
                    case None => ()
                }
                state.screen = "result"
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
            if (state.selected > 0) { state.selected = state.selected - 1 }
        case Action.NavigateDown =>
            if (state.selected + 1 < data.commands.size) { state.selected = state.selected + 1 }
        case Action.Toggle =>
            if (data.commands.size > 0) {
                data.commands[state.selected].authorized = !data.commands[state.selected].authorized
            }
        case Action.Run =>
            for (cmd in data.commands) { cmd.authorized = true }
        case Action.Confirm =>
            state.screen = "loading"
            state.loadingText = "Running authorized diagnostics...\n"
            state.retryText = ""
            runInvestigationTask(state.queue, session, data, config.execution.spawnTimeoutSec)
        case Action.Back | Action.Interrupt =>
            state.shouldExit = true
        case _ => ()
    }
}

func handleTextPromptAction(state: TuiAppState, session: Session, action: Action): Unit {
    match (action) {
        case Action.TextChar(ch) =>
            state.input += String(ch)
        case Action.Backspace =>
            if (state.input.size > 0) {
                state.input = state.input[0..state.input.size - 1]
            }
        case Action.Confirm | Action.Submit =>
            if (state.input.trimAscii().size > 0) {
                let submitted = state.input
                state.lastRequest = submitted
                state.screen = "loading"
                state.loadingText = ""
                state.retryText = ""
                state.input = ""
                startLlmTask(state.queue, session, submitted, true)
            }
        case Action.Back | Action.Interrupt =>
            state.screen = "result"
        case _ => ()
    }
}

func handleErrorAction(state: TuiAppState, session: Session, action: Action): Unit {
    match (action) {
        case Action.Confirm | Action.Run =>
            if (state.retryable) {
                state.screen = "loading"
                state.loadingText = ""
                state.retryText = ""
                startLlmTask(state.queue, session, state.lastRequest, true)
            }
        case Action.Back | Action.Interrupt =>
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
    state.screen = "execute"
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
                let prefix = if (line.isStderr) { "stderr: " } else { "stdout: " }
                state.executeLines.add(prefix + line.text)
            case None =>
                reading = false
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
}

func runInvestigationTask(queue: AppEventQueue, session: Session, data: InvestigateData, timeoutSec: Int64): Unit {
    spawn { =>
        try {
            let outputs = ArrayList<String>()
            for (cmd in data.commands) {
                if (cmd.authorized) {
                    let result = spawnCommandWithTimeout(cmd.command, timeoutSec * 1000)
                    var entry = "$ ${cmd.command}\n"
                    entry += "exit=${result.exitCode}\n"
                    if (result.stdout.size > 0) { entry += "stdout:\n${result.stdout}\n" }
                    if (result.stderr.size > 0) { entry += "stderr:\n${result.stderr}\n" }
                    outputs.add(entry)
                }
            }
            let response = session.modify(investigationSummary(data, outputs))
            queue.push(AppEvent.LLMDone(response))
        } catch (e: Exception) {
            queue.push(AppEvent.LLMError(e.message))
        }
    }
}

func copyCommandOrShowError(state: TuiAppState, command: String): Unit {
    match (copyToClipboard(command)) {
        case ClipResult.Ok =>
            state.shouldExit = true
        case ClipResult.Unsupported(reason) =>
            showError(state, "${reason}\n\n${clipboardInstallHint()}\n\nCommand:\n${command}", false)
    }
}

func openModify(state: TuiAppState, command: String): Unit {
    state.promptMode = "modify"
    state.input = ""
    state.loadingText = ""
    state.screen = "prompt"
    state.errorMessage = "Current command:\n${command}"
}

func showError(state: TuiAppState, message: String, retryable: Bool): Unit {
    state.errorMessage = message
    state.retryable = retryable
    state.screen = "error"
}

func render(terminal: Int64, state: TuiAppState): Unit {
    let spinnerFrame = state.tick / 4
    let content = buildScreenText(state, spinnerFrame)
    if (content == state.lastRenderedContent && spinnerFrame == state.lastSpinnerFrame) {
        return
    }

    state.lastRenderedContent = content
    state.lastSpinnerFrame = spinnerFrame

    // The terminal owns widget handles after addWidgetToTerminal() in this SDK.
    // Do not manually free handles that have been attached to the terminal.
    let _ = clearTerminalWidgets(terminal)
    state.widgetHandle = None
    match (createTextWidget(content)) {
        case Ok(handle) =>
            state.widgetHandle = Some(handle)
            let _ = setWidgetPosition(handle, 0, 0)
            let _ = setWidgetSize(handle, 80, 24)
            let _ = addWidgetToTerminal(terminal, handle)
        case Err(_) => ()
    }
    let _ = drawTerminal(terminal)
}

func buildScreenText(state: TuiAppState, renderTick: Int64): String {
    match (state.screen) {
        case "loading" => renderLoading(state.query, renderTick, state.loadingText, state.retryText)
        case "result" =>
            match (state.currentCommand) {
                case Some(data) => renderResult(data, state.selected)
                case None => renderError("No command is available.", false)
            }
        case "execute" => renderExecute(state.executeCommand, state.executeLines, state.executeDone, state.executeResult)
        case "prompt" => buildPromptText(state)
        case "error" => renderError(state.errorMessage, state.retryable)
        case _ => "termhelper\n"
    }
}

func buildPromptText(state: TuiAppState): String {
    if (state.promptMode == "investigate") {
        match (state.investigate) {
            case Some(data) => renderInvestigate(data, state.selected)
            case None => renderError("No investigation request is available.", false)
        }
    } else if (state.promptMode == "clarify") {
        match (state.clarify) {
            case Some(data) => renderTextPrompt("clarify", data.question, state.input, false)
            case None => renderError("No clarification question is available.", false)
        }
    } else {
        renderTextPrompt("modify", state.errorMessage, state.input, false)
    }
}
