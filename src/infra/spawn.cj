package termhelper.infra

import std.collection.*
import std.time.*
import std.sync.*
import termhelper.types.CommandResult

// ═══════════════════════════════════════════════════════════════
// 子进程执行 — 异步 spawn + 逐行回调 + 中断 + 超时
// 修复 #1: Channel 式逐行输出； #2: 中断支持； #3: 配置读取
// ═══════════════════════════════════════════════════════════════

foreign func pipe(fds: CPointer<Int32>): Int32
foreign func execve(path: CString, argv: CPointer<CPointer<Int8>>, envp: CPointer<CPointer<Int8>>): Int32

let WNOHANG: Int32 = 1

/// 单行输出
public struct OutputLine {
    public let text: String
    public let isStderr: Bool

    public init(text: String, isStderr: Bool) { this.text = text; this.isStderr = isStderr }
}

/// 异步 spawn 句柄 — 持有后台任务状态
public class SpawnHandle {
    // 共享缓冲区
    private let mtx: Mutex
    private let cond: Condition
    private var lines: ArrayList<OutputLine>
    private var done: Bool
    private var result: ?CommandResult

    // 中断标志
    private var interrupted: Bool
    private var childPid: Int32

    public init() {
        this.mtx = Mutex()
        this.lines = ArrayList<OutputLine>()
        this.done = false
        this.result = None
        this.interrupted = false
        this.childPid = -1
        this.cond = synchronized(mtx) { mtx.condition() }
    }

    /// 非阻塞读取下一行输出，无数据时返回 None
    public func tryReadLine(): ?OutputLine {
        synchronized(mtx) {
            if (lines.size > 0) {
                let line = lines[0]
                lines.remove(at: 0)
                Some(line)
            } else {
                None
            }
        }
    }

    /// 阻塞直到有数据或进程结束，返回 None 表示进程已结束且无更多数据
    public func readLine(): ?OutputLine {
        synchronized(mtx) {
            while (lines.size == 0 && !done) {
                cond.wait()
            }
            if (lines.size > 0) {
                let line = lines[0]
                lines.remove(at: 0)
                Some(line)
            } else {
                None
            }
        }
    }

    /// 发送中断信号
    public func interrupt(): Unit {
        synchronized(mtx) {
            interrupted = true
            if (childPid > 0) {
                unsafe {
                    kill(childPid, SIGTERM)
                }
            }
        }
    }

    /// 检查是否已结束
    public func isDone(): Bool {
        synchronized(mtx) { done }
    }

    /// 阻塞直到进程结束，返回结果
    public func waitDone(): CommandResult {
        synchronized(mtx) {
            while (!done) { cond.wait() }
            match (result) {
                case Some(r) => r
                case None => makeCommandResult(-1, "", "no result")
            }
        }
    }

    // ── 内部方法（由后台线程调用）──

    func addLine(line: OutputLine): Unit {
        synchronized(mtx) {
            lines.add(line)
            cond.notifyAll()
        }
    }

    func finish(res: CommandResult): Unit {
        synchronized(mtx) {
            done = true
            result = Some(res)
            cond.notifyAll()
        }
    }

    func isInterrupted(): Bool {
        synchronized(mtx) { interrupted }
    }

    func setPid(pid: Int32): Unit {
        synchronized(mtx) { childPid = pid }
    }
}

/// 异步执行命令，返回 SpawnHandle（非阻塞）
/// timeoutMs：超时毫秒。0 表示使用默认 300000（5min）。
public func spawnAsync(command: String, timeoutMs: Int64): SpawnHandle {
    let handle = SpawnHandle()
    let actualTimeout = if (timeoutMs <= 0) { 300000 } else { timeoutMs }

    spawn { =>
        let result = spawnInternal(command, actualTimeout, handle)
        handle.finish(result)
    }

    handle
}

/// 同步执行命令（兼容旧接口，内部复用 spawnInternal）
public func spawnCommand(command: String): CommandResult {
    spawnCommandWithTimeout(command, 300000)
}

/// 同步执行命令，带超时
public func spawnCommandWithTimeout(command: String, timeoutMs: Int64): CommandResult {
    spawnInternal(command, timeoutMs, None)
}

/// 简易执行（返回 exitCode + stdout）
public func spawnSimple(command: String): (Int32, String) {
    let result = spawnCommand(command)
    (result.exitCode, result.stdout)
}

/// 执行命令并分别返回 stdout/stderr
public func spawnWithStderr(command: String): (Int32, String, String) {
    let result = spawnCommand(command)
    (result.exitCode, result.stdout, result.stderr)
}

// ── 内部实现 ──

func spawnInternal(command: String, timeoutMs: Int64, handle: ?SpawnHandle): CommandResult {
    unsafe {
        let stdoutFds = LibC.malloc<Int32>(count: 2)
        let stderrFds = LibC.malloc<Int32>(count: 2)

        if (pipe(stdoutFds) < 0 || pipe(stderrFds) < 0) {
            LibC.free(stdoutFds); LibC.free(stderrFds)
            return makeCommandResult(-1, "", "pipe failed")
        }

        let stdoutRead = stdoutFds.read(0); let stdoutWrite = stdoutFds.read(1)
        let stderrRead = stderrFds.read(0); let stderrWrite = stderrFds.read(1)

        let pid = fork()
        if (pid < 0) {
            LibC.free(stdoutFds); LibC.free(stderrFds)
            return makeCommandResult(-1, "", "fork failed")
        }

        if (pid == 0) {
            close(stdoutRead); close(stderrRead)
            dup2(stdoutWrite, 1); dup2(stderrWrite, 2)
            close(stdoutWrite); close(stderrWrite)

            let shellPath = LibC.mallocCString("/bin/sh")
            let arg0 = LibC.mallocCString("sh"); let arg1 = LibC.mallocCString("-c")
            let cmdArg = LibC.mallocCString(command)

            let argvBuf = LibC.malloc<CPointer<Int8>>(count: 4)
            argvBuf.write(0, CPointer<Int8>(arg0.getChars()))
            argvBuf.write(1, CPointer<Int8>(arg1.getChars()))
            argvBuf.write(2, CPointer<Int8>(cmdArg.getChars()))
            argvBuf.write(3, CPointer<Int8>())

            execve(shellPath, argvBuf, CPointer<CPointer<Int8>>())
            _exit(127)
        }

        // 父进程
        match (handle) {
            case Some(h) => h.setPid(pid)
            case None => ()
        }

        close(stdoutWrite); close(stderrWrite)
        let startTime = MonoTime.now()
        var stdoutStr = ""; var stderrStr = ""
        let readBuf = LibC.malloc<UInt8>(count: 4096)
        let statusPtr = LibC.malloc<Int32>(count: 1)
        statusPtr.write(0, 0)
        var exitCode: Int32 = -1
        var finished = false

        // 行缓冲
        var stdoutLine = ""; var stderrLine = ""

        while (!finished) {
            // 中断检查
            let interrupted = match (handle) { case Some(h) => h.isInterrupted(); case None => false }
            if (interrupted) {
                kill(pid, SIGTERM)
                sleep(5 * Duration.second)
                let w2 = waitpid(pid, statusPtr, WNOHANG)
                if (w2 != pid) {
                    kill(pid, SIGKILL)
                    waitpid(pid, statusPtr, 0)
                }
                exitCode = -1
                finished = true
                continue
            }

            // 读取 stdout
            let n1 = read(stdoutRead, readBuf, 4096)
            if (n1 > 0) {
                for (i in 0..n1) {
                    let b = readBuf.read(i)
                    if (b == b'\n') {
                        stdoutStr += stdoutLine + "\n"
                        match (handle) {
                            case Some(h) => h.addLine(OutputLine(stdoutLine, false))
                            case None => ()
                        }
                        stdoutLine = ""
                    } else {
                        stdoutLine += String(Rune(Int32(b)))
                    }
                }
            }

            // 读取 stderr
            let n2 = read(stderrRead, readBuf, 4096)
            if (n2 > 0) {
                for (i in 0..n2) {
                    let b = readBuf.read(i)
                    if (b == b'\n') {
                        stderrStr += stderrLine + "\n"
                        match (handle) {
                            case Some(h) => h.addLine(OutputLine(stderrLine, true))
                            case None => ()
                        }
                        stderrLine = ""
                    } else {
                        stderrLine += String(Rune(Int32(b)))
                    }
                }
            }

            // 子进程退出检查
            let wResult = waitpid(pid, statusPtr, WNOHANG)
            if (wResult == pid) {
                let rawStatus = statusPtr.read(0)
                exitCode = if ((rawStatus & 0x7F) == 0) { (rawStatus >> 8) & 0xFF } else { -1 }
                finished = true
            }

            // 超时检查 — SIGTERM → 等 5s → SIGKILL
            let elapsed = MonoTime.now() - startTime
            if (elapsed > Duration.millisecond * timeoutMs) {
                kill(pid, SIGTERM)
                sleep(5 * Duration.second)
                let w2 = waitpid(pid, statusPtr, WNOHANG)
                if (w2 != pid) {
                    kill(pid, SIGKILL)
                    waitpid(pid, statusPtr, 0)
                }
                finished = true
            }
        }

        // 消费剩余输出
        var n = read(stdoutRead, readBuf, 4096)
        while (n > 0) {
            for (i in 0..n) { stdoutStr += String(Rune(Int32(readBuf.read(i)))) }
            n = read(stdoutRead, readBuf, 4096)
        }
        n = read(stderrRead, readBuf, 4096)
        while (n > 0) {
            for (i in 0..n) { stderrStr += String(Rune(Int32(readBuf.read(i)))) }
            n = read(stderrRead, readBuf, 4096)
        }

        // 排干行缓冲中的残留
        if (stdoutLine.size > 0) { stdoutStr += stdoutLine; match (handle) { case Some(h) => h.addLine(OutputLine(stdoutLine, false)); case None => () } }
        if (stderrLine.size > 0) { stderrStr += stderrLine; match (handle) { case Some(h) => h.addLine(OutputLine(stderrLine, true)); case None => () } }

        close(stdoutRead); close(stderrRead)
        LibC.free(readBuf); LibC.free(statusPtr)
        LibC.free(stdoutFds); LibC.free(stderrFds)

        makeCommandResult(exitCode, stdoutStr, stderrStr)
    }
}

func makeCommandResult(exitCode: Int32, stdout: String, stderr: String): CommandResult {
    let r = CommandResult()
    r.exitCode = exitCode
    r.stdout = stdout
    r.stderr = stderr
    r
}
