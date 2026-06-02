package termhelper.tui

import termhelper.infra.*
import termhelper.types.*

// ═══════════════════════════════════════════════════════════════
// 信号处理模块
// SIGWINCH: 由 ratatui 的 pollEvent 自动检测（crossterm 内部处理）
// SIGINT:   raw mode 下 Ctrl-C 作为键事件处理（input.cj 中已映射）
// SIGTERM:  注册信号处理器，通过 AppEvent 通知主循环
// SIGHUP:   同 SIGTERM
//
// 注意: 仓颉 FFI 不支持函数指针参数，signal() 注册降级为 self-pipe trick。
//       当前实现：SIGTERM/SIGHUP 通过 self-pipe 通知主循环。
// ═══════════════════════════════════════════════════════════════

// ── 本地 FFI 声明（infra 包的 FFI 为包内私有，需重新声明）──

foreign func pipe(fds: CPointer<Int32>): Int32
foreign func fcntl(fd: Int32, cmd: Int32, ...): Int32
foreign func read(fd: Int32, buf: CPointer<UInt8>, count: UInt64): Int64
foreign func close(fd: Int32): Int32

let F_GETFL: Int32 = 3
let F_SETFL: Int32 = 4
let O_NONBLOCK: Int32 = 0x800

// ── self-pipe 用于信号通知 ──

var signalPipeReadFd: Int32 = -1
var signalPipeWriteFd: Int32 = -1

/// 初始化 self-pipe（在主线程调用）
public func initSignalPipe(): Unit {
    unsafe {
        let fds = LibC.malloc<Int32>(count: 2)
        if (pipe(fds) == 0) {
            signalPipeReadFd = fds.read(0)
            signalPipeWriteFd = fds.read(1)
            // 设置非阻塞
            let flags = fcntl(signalPipeReadFd, F_GETFL)
            if (flags >= 0) {
                fcntl(signalPipeReadFd, F_SETFL, flags | O_NONBLOCK)
            }
        }
        LibC.free(fds)
    }
}

/// 检查是否有信号到达（非阻塞，在主循环中调用）
/// 返回信号编号，无信号返回 -1
public func pollSignal(): Int32 {
    if (signalPipeReadFd < 0) { return -1 }
    unsafe {
        let buf = LibC.malloc<UInt8>(count: 1)
        let n = read(signalPipeReadFd, buf, 1)
        if (n > 0) {
            let sig = Int32(buf.read(0))
            LibC.free(buf)
            return sig
        }
        LibC.free(buf)
    }
    -1
}

/// 关闭信号管道
public func closeSignalPipe(): Unit {
    if (signalPipeReadFd >= 0) {
        unsafe { close(signalPipeReadFd) }
        signalPipeReadFd = -1
    }
    if (signalPipeWriteFd >= 0) {
        unsafe { close(signalPipeWriteFd) }
        signalPipeWriteFd = -1
    }
}

// ── 信号处理器（需要 C 函数指针，当前为占位）──

// 由于仓颉 FFI 不支持函数指针参数，signal() 注册暂不实现。
// SIGTERM/SIGHUP 的实际处理依赖以下降级方案：
// 1. SIGINT: raw mode 下 Ctrl-C 作为键事件处理
// 2. SIGWINCH: ratatui/crossterm 自动处理，返回 resize 事件
// 3. SIGTERM/SIGHUP: 进程被 kill 时的默认行为（退出）
//    未来可通过 self-pipe + signal() 注册实现优雅退出。
