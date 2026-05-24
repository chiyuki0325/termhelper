package termhelper.tui

import ratatui.core.*

/// TUI 初始化、主循环、Screen 路由、Channel 接收
/// 阶段 1 占位：仅验证终端初始化和事件轮询

/// 初始化 TUI，进入 alternate screen + raw mode
public func initTUI(): Result<Int64, RatatuiException> {
    initTerminal()
}

/// 运行主循环（占位：轮询事件直到收到 Quit 或 Esc）
public func runMainLoop(terminal: Int64): Result<Unit, RatatuiException> {
    var running = true
    while (running) {
        match (pollEvent(100)) {
            case Some(eventHandle) =>
                if (eventIsQuit(eventHandle)) {
                    running = false
                } else if (eventIsKey(eventHandle)) {
                    let code = eventGetKeyCode(eventHandle)
                    // Esc 键退出
                    if (code == 27) {
                        running = false
                    }
                }
                eventFree(eventHandle)
            case None => ()
        }
        drawTerminal(terminal)
    }
    Result.Ok(())
}

/// 清理 TUI，恢复终端模式
public func cleanupTUI(terminal: Int64): Result<Unit, RatatuiException> {
    cleanupTerminal(terminal)
}
