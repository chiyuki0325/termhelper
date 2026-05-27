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
            state.loadingText = "正在运行已授权的诊断命令...\n"
            state.retryText = ""
            runInvestigationTask(state.queue, session, data, config.execution.spawnTimeoutSec)
        case Action.Back | Action.Interrupt =>
            state.shouldExit = true
        case _ => ()
    }
}

func handleTextPromptAction(state: TuiAppState, session: Session, action: Action): Unit {
    match (action) {
        case Action.TextInput(text) =>
            state.input += text
        case Action.Run =>
            state.input += "r"
        case Action.Copy =>
            state.input += "c"
        case Action.Modify =>
            state.input += "m"
        case Action.Toggle =>
            state.input += " "
        case Action.Backspace =>
            if (state.input.size > 0) {
                state.input = removeLastRune(state.input)
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
                if (line.isStderr) {
                    state.executeLines.add("stderr: " + line.text)
                } else {
                    state.executeLines.add(line.text)
                }
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
            showError(state, "${reason}\n\n${clipboardInstallHint()}\n\n命令:\n${command}", false)
    }
}

func openModify(state: TuiAppState, command: String): Unit {
    state.promptMode = "modify"
    state.input = ""
    state.loadingText = ""
    state.screen = "prompt"
    state.errorMessage = "写出命令修改建议。\n\n当前命令:\n${command}"
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
                let _ = addWidgetToTerminal(terminal, handle)
            case Err(_) => ()
        }
    }
    let _ = drawTerminal(terminal)
}

func renderStyledContent(terminal: Int64, state: TuiAppState, spinnerFrame: Int64): Bool {
    match (createRichTextWidget()) {
        case Ok(handle) =>
            state.widgetHandle = Some(handle)
            buildStyledScreen(handle, state, spinnerFrame)
            let _ = setWidgetPosition(handle, 2, 1)
            let _ = setWidgetSize(handle, 0, 0)
            let _ = addWidgetToTerminal(terminal, handle)
            true
        case Err(_) => false
    }
}

func buildStyledScreen(handle: Int64, state: TuiAppState, spinnerFrame: Int64): Unit {
    match (state.screen) {
        case "loading" => styledLoading(handle, state.query, spinnerFrame, state.loadingText, state.retryText)
        case "result" =>
            match (state.currentCommand) {
                case Some(data) => styledResult(handle, data, state.selected)
                case None => styledError(handle, "当前没有可用命令。", false)
            }
        case "execute" => styledExecute(handle, state.executeCommand, state.executeLines, state.executeDone, state.executeResult)
        case "prompt" => styledPrompt(handle, state)
        case "error" => styledError(handle, state.errorMessage, state.retryable)
        case _ => richTextLine(handle, "智能终端助手", styleTitle())
    }
}

func styledLoading(handle: Int64, query: String, frame: Int64, streamedText: String, retryText: String): Unit {
    richTextSpan(handle, "正在生成命令", styleTitle())
    richTextSpan(handle, "  " + spinnerFrame(frame), styleInfo())
    richTextLine(handle)
    richTextLine(handle)
    styledSection(handle, "查询")
    styledWrapped(handle, "  " + query, UI_WIDTH - 2, "  ", styleDefault())
    if (retryText.size > 0) {
        richTextLine(handle)
        styledSection(handle, "重试")
        styledWrapped(handle, "  " + retryText, UI_WIDTH - 2, "  ", styleWarning())
    }
    richTextLine(handle)
    styledSection(handle, "模型响应")
    if (streamedText.size == 0) {
        richTextLine(handle, "  正在等待模型响应...", styleMuted())
    } else {
        styledWrapped(handle, streamedText, UI_WIDTH, "", styleDefault())
    }
    styledKeys(handle, "Esc / Ctrl-C 退出")
}

func styledResult(handle: Int64, data: CommandData, selected: Int64): Unit {
    richTextSpan(handle, "已生成命令", styleTitle())
    richTextSpan(handle, "  " + if (data.interactive) { "需要交互" } else { "可运行" }, if (data.interactive) { styleWarning() } else { styleSuccess() })
    richTextLine(handle)
    richTextLine(handle)
    styledSection(handle, "命令")
    richTextSpan(handle, "  $ ", styleMuted())
    richTextLine(handle, data.command, styleCommand())
    if (data.explanation.summary.size > 0) {
        styledField(handle, "摘要", data.explanation.summary, styleDefault())
    }
    richTextLine(handle)
    styledSection(handle, "分解说明")
    if (data.explanation.breakdown.size == 0) {
        richTextLine(handle, "  模型没有提供分解说明。", styleMuted())
    } else {
        for (item in data.explanation.breakdown) {
            styledBreakdownItem(handle, item.component, item.explanation)
        }
    }
    richTextLine(handle)
    styledSection(handle, "安全性")
    richTextLine(handle, "  " + safetyMarker(data.safety.level) + " " + safetyLabel(data.safety.level), styleSafety(data.safety.level))
    if (data.safety.warnings.size == 0) {
        richTextLine(handle, "  没有安全警告。", styleMuted())
    } else {
        for (warning in data.safety.warnings) {
            styledWrapped(handle, "  * " + warning, UI_WIDTH - 4, "    ", styleWarning())
        }
    }
    richTextLine(handle)
    styledOptionMenu(handle, resultMenu(data.interactive), selected)
    styledKeys(handle, "上/下 选择  Enter 确认  R 运行  C 复制  M 修改  Esc 退出")
}

func styledExecute(handle: Int64, command: String, lines: ArrayList<String>, done: Bool, result: ?CommandResult): Unit {
    richTextSpan(handle, "命令执行", styleTitle())
    richTextSpan(handle, "  " + if (done) { "已结束" } else { "运行中" }, if (done) { styleSuccess() } else { styleInfo() })
    richTextLine(handle)
    richTextLine(handle)
    styledSection(handle, "命令")
    richTextSpan(handle, "  $ ", styleMuted())
    richTextLine(handle, command, styleCommand())
    richTextLine(handle)
    styledSection(handle, "结果")
    styledField(handle, "状态", if (done) { "已结束" } else { "运行中" }, if (done) { styleSuccess() } else { styleInfo() })
    match (result) {
        case Some(r) => styledField(handle, "退出码", "${r.exitCode}", if (r.exitCode == 0) { styleSuccess() } else { styleErrorText() })
        case None => ()
    }
    richTextLine(handle)
    styledSection(handle, "输出")
    let start = if (lines.size > 14) { lines.size - 14 } else { 0 }
    for (i in start..lines.size) {
        let isErr = lines[i].startsWith("stderr: ")
        let displayLine = if (isErr) { lines[i][8..] } else { lines[i] }
        let lineStyle = if (isErr) { styleErrorText() } else { styleDefault() }
        styledWrapped(handle, "  " + displayLine, UI_WIDTH - 2, "  ", lineStyle)
    }
    if (lines.size == 0) {
        richTextLine(handle, "  还没有输出。", styleMuted())
    }
    styledKeys(handle, if (done) { "Ctrl-C / Esc / Enter 退出" } else { "Ctrl-C 中断  Esc 返回" })
}

func styledPrompt(handle: Int64, state: TuiAppState): Unit {
    if (state.promptMode == "investigate") {
        match (state.investigate) {
            case Some(data) => styledInvestigate(handle, data, state.selected)
            case None => styledError(handle, "当前没有可用的调查请求。", false)
        }
    } else if (state.promptMode == "clarify") {
        match (state.clarify) {
            case Some(data) => styledTextPrompt(handle, "澄清", data.question, state.input, false)
            case None => styledError(handle, "当前没有可用的澄清问题。", false)
        }
    } else {
        styledTextPrompt(handle, "修改", state.errorMessage, state.input, false)
    }
}

func styledInvestigate(handle: Int64, data: InvestigateData, selected: Int64): Unit {
    richTextSpan(handle, "需要环境调查", styleTitle())
    richTextSpan(handle, "  ${data.commands.size} 项检查", styleWarning())
    richTextLine(handle)
    richTextLine(handle)
    styledSection(handle, "原因")
    styledWrapped(handle, "  " + data.reason, UI_WIDTH - 2, "  ", styleDefault())
    richTextLine(handle)
    styledSection(handle, "诊断命令")
    for (i in 0..data.commands.size) {
        let cmd = data.commands[i]
        let cursor = if (i == selected) { "  > " } else { "    " }
        let mark = if (cmd.authorized) { "[x] " } else { "[ ] " }
        richTextLine(handle, cursor + mark + cmd.command, if (i == selected) { styleSelected() } else { styleCommand() })
        styledWrapped(handle, "      " + cmd.rationale, UI_WIDTH - 6, "      ", styleMuted())
    }
    styledKeys(handle, "Space 切换授权  Enter 运行已授权命令  R 全部授权  Esc 退出")
}

func styledTextPrompt(handle: Int64, title: String, question: String, current: String, sensitive: Bool): Unit {
    richTextSpan(handle, title, styleTitle())
    richTextSpan(handle, "  等待输入", styleInfo())
    richTextLine(handle)
    if (question.size > 0) {
        richTextLine(handle)
        styledSection(handle, "提示")
        styledWrapped(handle, question, UI_WIDTH, "", styleDefault())
    }
    richTextLine(handle)
    styledSection(handle, "输入")
    styledInputBox(handle, if (sensitive) { maskedInput(current) } else { current })
    styledKeys(handle, "Enter 提交  Esc 取消")
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
    for (_ in current.runes()) { out += "*" }
    out
}

func styledError(handle: Int64, message: String, retryable: Bool): Unit {
    richTextSpan(handle, "出现错误", styleErrorText())
    if (retryable) {
        richTextSpan(handle, "  可重试", styleWarning())
    }
    richTextLine(handle)
    richTextLine(handle)
    styledWrapped(handle, message, UI_WIDTH, "", styleDefault())
    if (retryable) {
        richTextLine(handle)
        styledSection(handle, "恢复")
        richTextLine(handle, "  按 Enter/R 重试上一次请求。", styleMuted())
    }
    styledKeys(handle, "Esc / Ctrl-C 退出")
}

func styledOptionMenu(handle: Int64, items: ArrayList<MenuItem>, selected: Int64): Unit {
    styledSection(handle, "操作")
    for (i in 0..items.size) {
        let prefix = if (i == selected) { "  > " } else { "    " }
        richTextLine(handle, prefix + items[i].label, if (i == selected) { styleSelected() } else { styleDefault() })
    }
}

func styledSection(handle: Int64, title: String): Unit {
    richTextLine(handle, title, styleSection())
}

func styledField(handle: Int64, label: String, value: String, valueStyle: RichStyle): Unit {
    richTextSpan(handle, "  " + label + "：", styleMuted())
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
    match (createBlockWidget("智能终端助手 » 样式预览")) {
        case Ok(handle) =>
            let _ = setWidgetPosition(handle, 0, 0)
            let _ = setWidgetSize(handle, 0, 0)
            let _ = addWidgetToTerminal(terminal, handle)
        case Err(_) => ()
    }

    match (createRichTextWidget()) {
        case Ok(handle) =>
            richTextSpan(handle, "已生成命令", styleTitle())
            richTextSpan(handle, "  可运行", styleSuccess())
            richTextLine(handle)
            richTextLine(handle)

            richTextLine(handle, "查询", styleSection())
            richTextLine(handle, "  列出 /tmp 里的文件", styleDefault())
            richTextLine(handle)

            richTextLine(handle, "命令", styleSection())
            richTextSpan(handle, "  $ ", styleMuted())
            richTextLine(handle, "ls /tmp", styleCommand())
            richTextLine(handle, "  摘要：列出临时目录中的文件和子目录。", styleDefault())
            richTextLine(handle)

            richTextLine(handle, "安全性", styleSection())
            richTextSpan(handle, "  [+] 安全", styleSuccess())
            richTextLine(handle, "  不修改文件系统。", styleMuted())
            richTextLine(handle)

            richTextLine(handle, "操作", styleSection())
            richTextLine(handle, "  > 运行", styleSelected())
            richTextLine(handle, "    复制", styleDefault())
            richTextLine(handle, "    修改", styleDefault())
            richTextLine(handle)

            richTextSpan(handle, "Enter 确认  R 运行  C 复制  M 修改  Esc 退出", styleMuted())
            let _ = setWidgetPosition(handle, 2, 1)
            let _ = setWidgetSize(handle, 0, 0)
            let _ = addWidgetToTerminal(terminal, handle)
        case Err(_) => ()
    }
    let _ = drawTerminal(terminal)
}

func screenTitle(state: TuiAppState): String {
    match (state.screen) {
        case "loading" => "智能终端助手 » 思考中"
        case "result" => "智能终端助手 » 结果"
        case "execute" => "智能终端助手 » 执行"
        case "prompt" =>
            if (state.promptMode == "investigate") {
                "智能终端助手 » 环境调查"
            } else if (state.promptMode == "clarify") {
                "智能终端助手 » 澄清"
            } else {
                "智能终端助手 » 修改"
            }
        case "error" => "智能终端助手 » 错误"
        case _ => "智能终端助手"
    }
}

func buildScreenText(state: TuiAppState, renderTick: Int64): String {
    match (state.screen) {
        case "loading" => renderLoading(state.query, renderTick, state.loadingText, state.retryText)
        case "result" =>
            match (state.currentCommand) {
                case Some(data) => renderResult(data, state.selected)
                case None => renderError("当前没有可用命令。", false)
            }
        case "execute" => renderExecute(state.executeCommand, state.executeLines, state.executeDone, state.executeResult)
        case "prompt" => buildPromptText(state)
        case "error" => renderError(state.errorMessage, state.retryable)
        case _ => "智能终端助手\n"
    }
}

func buildPromptText(state: TuiAppState): String {
    if (state.promptMode == "investigate") {
        match (state.investigate) {
            case Some(data) => renderInvestigate(data, state.selected)
            case None => renderError("当前没有可用的调查请求。", false)
        }
    } else if (state.promptMode == "clarify") {
        match (state.clarify) {
            case Some(data) => renderTextPrompt("澄清", data.question, state.input, false)
            case None => renderError("当前没有可用的澄清问题。", false)
        }
    } else {
        renderTextPrompt("修改", state.errorMessage, state.input, false)
    }
}
