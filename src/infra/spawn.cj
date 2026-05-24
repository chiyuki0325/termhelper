package termhelper.infra

import std.collection.*
import std.time.*

// ═══════════════════════════════════════════════════════════════
// 子进程执行 — spawn + 输出捕获 + 超时 + 中断
// 依赖 util.cj 中的 FFI 声明 (fork/waitpid/_exit/close/read)
// ═══════════════════════════════════════════════════════════════

foreign func pipe(fds: CPointer<Int32>): Int32
foreign func execve(path: CString, argv: CPointer<CPointer<Int8>>, envp: CPointer<CPointer<Int8>>): Int32

let WNOHANG: Int32 = 1

/// 执行 shell 命令并收集合并输出
/// 返回 (exitCode, combinedOutput)
public func spawnSimple(command: String): (Int32, String) {
    spawnWithTimeout(command, 300000)
}

/// 执行 shell 命令，支持超时（毫秒）
func spawnWithTimeout(command: String, timeoutMs: Int64): (Int32, String) {
    unsafe {
        let fds = LibC.malloc<Int32>(count: 2)
        if (pipe(fds) < 0) { LibC.free(fds); return (-1, "pipe failed") }

        let readFd = fds.read(0)
        let writeFd = fds.read(1)
        let pid = fork()

        if (pid < 0) {
            LibC.free(fds)
            return (-1, "fork failed")
        }

        if (pid == 0) {
            close(readFd)
            dup2(writeFd, 1)
            dup2(writeFd, 2)
            close(writeFd)

            let shellPath = LibC.mallocCString("/bin/sh")
            let arg0 = LibC.mallocCString("sh")
            let arg1 = LibC.mallocCString("-c")
            let cmdArg = LibC.mallocCString(command)

            let argvBuf = LibC.malloc<CPointer<Int8>>(count: 4)
            argvBuf.write(0, CPointer<Int8>(arg0.getChars()))
            argvBuf.write(1, CPointer<Int8>(arg1.getChars()))
            argvBuf.write(2, CPointer<Int8>(cmdArg.getChars()))
            argvBuf.write(3, CPointer<Int8>())

            execve(shellPath, argvBuf, CPointer<CPointer<Int8>>())
            _exit(127)
        }

        // 仅父进程到达此处
        close(writeFd)

        let startTime = MonoTime.now()
        var output = ""
        let readBuf = LibC.malloc<UInt8>(count: 4096)
        let statusPtr = LibC.malloc<Int32>(count: 1)
        statusPtr.write(0, 0)
        var exitCode: Int32 = -1
        var finished = false

        while (!finished) {
            let n = read(readFd, readBuf, 4096)
            if (n > 0) {
                for (i in 0..n) {
                    output += String(Rune(Int32(readBuf.read(i))))
                }
            }
            let wResult = waitpid(pid, statusPtr, WNOHANG)
            if (wResult == pid) {
                let rawStatus = statusPtr.read(0)
                exitCode = if ((rawStatus & 0x7F) == 0) { (rawStatus >> 8) & 0xFF } else { -1 }
                finished = true
            }
            let elapsed = MonoTime.now() - startTime
            if (elapsed > Duration.millisecond * timeoutMs) {
                kill(pid, SIGTERM)
                kill(pid, SIGKILL)
                finished = true
            }
        }

        // 读取剩余输出
        var n = read(readFd, readBuf, 4096)
        while (n > 0) {
            for (i in 0..n) { output += String(Rune(Int32(readBuf.read(i)))) }
            n = read(readFd, readBuf, 4096)
        }

        close(readFd)
        LibC.free(readBuf); LibC.free(statusPtr); LibC.free(fds)
        (exitCode, output)
    }
}

/// 执行命令，分别捕获 stdout 和 stderr（当前简化：合并输出）
public func spawnWithStderr(command: String): (Int32, String, String) {
    let (code, output) = spawnWithTimeout(command, 300000)
    (code, output, "")
}
