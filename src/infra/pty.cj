package termhelper.infra

// ═══════════════════════════════════════════════════════════════
// PTY 基础设施 — 基于 musl openpty/pty.c 实现
// 参考: references/musl/src/misc/openpty.c, pty.c
// ═══════════════════════════════════════════════════════════════

import std.collection.*

// ── ioctl 常量（aarch64 Linux 正确值）──
// T=0x54, _IOC_READ=0x80000000, _IOC_WRITE=0x40000000

let TIOCGPTN: Int64 = 0x80045430    // _IOR('T', 0x30, int) — 获取 pty 编号
let TIOCSPTLCK: Int64 = 0x40045431 // _IOW('T', 0x31, int) — 设置/清除 pty 锁
let TIOCSWINSZ: Int64 = 0x40085434 // _IOW('T', 0x34, winsize) — 设置终端窗口大小
let TIOCGWINSZ: Int64 = 0x80085435 // _IOR('T', 0x35, winsize) — 获取终端窗口大小

// ── fcntl 常量 ──

let F_GETFL: Int32 = 3
let F_SETFL: Int32 = 4
let O_NONBLOCK: Int32 = 0x800
let O_RDWR: Int32 = 2
let O_NOCTTY: Int32 = 0x100

// ── FFI ──

foreign func ioctl(fd: Int32, request: Int64, ...): Int32
foreign func fcntl(fd: Int32, cmd: Int32, ...): Int32
foreign func setsid(): Int32
foreign func execvp(file: CString, argv: CPointer<CPointer<Int8>>): Int32

// ── Winsize 结构体（for TIOCSWINSZ）──

@C
struct Winsize {
    var ws_row: UInt16 = 0
    var ws_col: UInt16 = 0
    var ws_xpixel: UInt16 = 0
    var ws_ypixel: UInt16 = 0

    public init(rows: UInt16, cols: UInt16) {
        this.ws_row = rows; this.ws_col = cols
        this.ws_xpixel = 0; this.ws_ypixel = 0
    }
}

// ── Pty 类型 ──

/// PTY 句柄
public class Pty {
    public let masterFd: Int32
    public let slavePath: String
    private var childPid: Int32
    private var closed: Bool

    private init(masterFd: Int32, slavePath: String, childPid: Int32) {
        this.masterFd = masterFd
        this.slavePath = slavePath
        this.childPid = childPid
        this.closed = false
    }

    ~init() {
        if (!closed) {
            closed = true
            if (childPid > 0) {
                unsafe {
                    kill(childPid, SIGTERM)
                    kill(childPid, SIGKILL)
                }
            }
            unsafe { close(masterFd) }
        }
    }

    /// 创建 PTY 并设置终端大小
    public static func create(rows: UInt16, cols: UInt16): ?Pty {
        unsafe {
            // 1. 打开 /dev/ptmx（参考 musl posix_openpt）
            let ptmxPath = LibC.mallocCString("/dev/ptmx")
            let mfd = open(ptmxPath, O_RDWR | O_NOCTTY, 0)
            LibC.free(ptmxPath)

            if (mfd < 0) { return None }

            // 2. grantpt — Linux 上为 no-op
            // 3. unlockpt（参考 musl pty.c）
            var unlock: Int32 = 0
            if (ioctl(mfd, TIOCSPTLCK, inout unlock) < 0) {
                close(mfd)
                return None
            }

            // 4. 获取 pty 编号（参考 musl __ptsname_r）
            var ptyNum: Int32 = 0
            if (ioctl(mfd, TIOCGPTN, inout ptyNum) < 0) {
                close(mfd)
                return None
            }
            let slavePath = "/dev/pts/${ptyNum}"

            // 5. 设置终端大小（非致命）
            var ws = Winsize(rows, cols)
            ioctl(mfd, TIOCSWINSZ, inout ws)  // 忽略返回值

            // 6. 设置非阻塞
            let flags = fcntl(mfd, F_GETFL)
            if (flags >= 0) {
                fcntl(mfd, F_SETFL, flags | O_NONBLOCK)
            }

            Some(Pty(mfd, slavePath, -1))
        }
    }

    /// 在 PTY 中启动子进程（fork + setsid + exec）
    public func spawnChild(command: String): Bool {
        unsafe {
            let pid = fork()
            if (pid < 0) { return false }

            if (pid == 0) {
                // 子进程：创建新会话，连接 slave
                setsid()

                let slavePathC = LibC.mallocCString(slavePath)
                let sfd = open(slavePathC, O_RDWR, 0)
                LibC.free(slavePathC)

                if (sfd >= 0) {
                    dup2(sfd, 0)  // stdin
                    dup2(sfd, 1)  // stdout
                    dup2(sfd, 2)  // stderr
                    if (sfd > 2) { close(sfd) }
                }

                // 执行 /bin/sh -c command
                let shell = LibC.mallocCString("/bin/sh")
                let arg0 = LibC.mallocCString("sh")
                let arg1 = LibC.mallocCString("-c")
                let cmdC = LibC.mallocCString(command)

                let argv = LibC.malloc<CPointer<Int8>>(count: 4)
                argv.write(0, CPointer<Int8>(arg0.getChars()))
                argv.write(1, CPointer<Int8>(arg1.getChars()))
                argv.write(2, CPointer<Int8>(cmdC.getChars()))
                argv.write(3, CPointer<Int8>())

                execvp(shell, argv)
                _exit(127)
            }

            this.childPid = pid
            true
        }
    }

    /// 非阻塞读取 PTY 输出
    public func tryRead(bufSize: Int64): String {
        unsafe {
            let buf = LibC.malloc<UInt8>(count: bufSize)
            let n = read(masterFd, buf, UInt64(bufSize))
            if (n <= 0) { LibC.free(buf); return "" }

            let arr = Array<UInt8>(n, repeat: 0)
            for (i in 0..n) { arr[i] = buf.read(i) }
            LibC.free(buf)
            String.fromUtf8(arr)
        }
    }

    /// 写入 PTY（如密码、确认等）
    public func writeData(data: String): Int64 {
        unsafe {
            let bytes = data.toArray()
            let wbuf = LibC.malloc<UInt8>(count: bytes.size)
            for (i in 0..bytes.size) { wbuf.write(i, bytes[i]) }
            let written = write(masterFd, wbuf, UInt64(bytes.size))
            LibC.free(wbuf)
            written
        }
    }

    /// 调整 PTY 终端大小
    public func resize(rows: UInt16, cols: UInt16): Bool {
        if (closed) { return false }
        var ws = Winsize(rows, cols)
        unsafe { ioctl(masterFd, TIOCSWINSZ, inout ws) >= 0 }
    }

    /// 检查子进程是否已退出
    public func childExited(): Bool {
        if (childPid < 0) { return true }
        unsafe {
            let statusPtr = LibC.malloc<Int32>(count: 1)
            statusPtr.write(0, 0)
            let result = waitpid(childPid, statusPtr, WNOHANG)
            let exited = result == childPid
            LibC.free(statusPtr)
            exited
        }
    }

    /// 获取子进程退出码（仅在 childExited 后有效）
    public func getExitCode(): Int32 {
        if (childPid < 0) { return -1 }
        unsafe {
            let statusPtr = LibC.malloc<Int32>(count: 1)
            statusPtr.write(0, 0)
            waitpid(childPid, statusPtr, 0)
            let raw = statusPtr.read(0)
            LibC.free(statusPtr)
            if ((raw & 0x7F) == 0) { return (raw >> 8) & 0xFF } else { return -1 }
        }
    }

    /// 发送信号给子进程
    public func killChild(sig: Int32): Unit {
        if (childPid > 0) {
            unsafe { kill(childPid, sig) }
        }
    }

    /// 关闭 PTY 并清理子进程
    public func close(): Unit {
        if (closed) { return }
        closed = true

        if (childPid > 0) {
            killChild(SIGTERM)
            killChild(SIGKILL)
        }
        unsafe { close(masterFd) }
    }

    /// 获取终端大小
    public func getSize(): (UInt16, UInt16) {
        var ws = Winsize(0, 0)
        unsafe { ioctl(masterFd, TIOCGWINSZ, inout ws) }
        (ws.ws_col, ws.ws_row)
    }
}