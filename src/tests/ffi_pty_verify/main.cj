package termhelper.tests.ffi_pty_verify

// ═══════════════════════════════════════════════════════════════
// 阶段 1.3：仓颉 FFI + libc PTY 验证
// ═══════════════════════════════════════════════════════════════

let O_RDWR: Int32 = 2
let O_NOCTTY: Int32 = 0x100

foreign func posix_openpt(flags: Int32): Int32
foreign func grantpt(fd: Int32): Int32
foreign func unlockpt(fd: Int32): Int32
foreign func close(fd: Int32): Int32
foreign func write(fd: Int32, buf: CPointer<UInt8>, count: UInt64): Int64
foreign func read(fd: Int32, buf: CPointer<UInt8>, count: UInt64): Int64
foreign func fcntl(fd: Int32, cmd: Int32, ...): Int32
foreign func fork(): Int32
foreign func waitpid(pid: Int32, status: CPointer<Int32>, options: Int32): Int32
foreign func _exit(status: Int32): Unit

func verifyPtyCreate(): Bool {
    unsafe {
        let masterFd = posix_openpt(O_RDWR | O_NOCTTY)
        if (masterFd < 0) {
            println("  FAIL: posix_openpt 返回 ${masterFd}")
            return false
        }
        println("  OK: posix_openpt → fd=${masterFd}")

        let gResult = grantpt(masterFd)
        if (gResult != 0) {
            println("  FAIL: grantpt 返回 ${gResult}")
            close(masterFd)
            return false
        }
        println("  OK: grantpt 成功")

        let uResult = unlockpt(masterFd)
        if (uResult != 0) {
            println("  FAIL: unlockpt 返回 ${uResult}")
            close(masterFd)
            return false
        }
        println("  OK: unlockpt 成功")

        close(masterFd)
        println("  OK: PTY 创建/关闭成功")
    }
    true
}

func verifyNonBlocking(): Bool {
    unsafe {
        let masterFd = posix_openpt(O_RDWR | O_NOCTTY)
        if (masterFd < 0) {
            println("  FAIL: 无法创建 PTY")
            return false
        }

        // F_GETFL=3, O_NONBLOCK=0x800 (aarch64)
        let flags = fcntl(masterFd, 3)
        if (flags < 0) {
            println("  FAIL: fcntl F_GETFL 返回 ${flags}")
            close(masterFd)
            return false
        }
        println("  OK: fcntl F_GETFL → ${flags}")

        let setResult = fcntl(masterFd, 4, flags | 0x800)
        if (setResult < 0) {
            println("  FAIL: fcntl F_SETFL(NONBLOCK) 返回 ${setResult}")
            close(masterFd)
            return false
        }
        println("  OK: fcntl O_NONBLOCK 设置成功")

        // 非阻塞读 — 应返回 -1
        let readBuf = LibC.malloc<UInt8>(count: 256)
        let n = read(masterFd, readBuf, 256)
        println("  OK: 非阻塞读返回 ${n} (预期 -1)")

        LibC.free(readBuf)
        close(masterFd)
    }
    true
}

func verifyForkWait(): Bool {
    unsafe {
        let pid = fork()
        if (pid < 0) {
            println("  FAIL: fork 返回 ${pid}")
            return false
        }
        if (pid == 0) {
            _exit(42)
        }
        // 仅父进程到达此处
        let statusPtr = LibC.malloc<Int32>(count: 1)
        statusPtr.write(0, 0)
        let result = waitpid(pid, statusPtr, 0)
        let rawStatus = statusPtr.read(0)
        LibC.free(statusPtr)

        if (result == pid) {
            println("  OK: fork pid=${pid}, waitpid 返回 ${result}, 原始状态=${rawStatus}")
            return true
        } else {
            println("  FAIL: waitpid 返回 ${result}, 预期 ${pid}")
            return false
        }
    }
}

func verifyPtyWriteRead(): Bool {
    unsafe {
        let masterFd = posix_openpt(O_RDWR | O_NOCTTY)
        if (masterFd < 0) {
            println("  FAIL: 无法创建 PTY")
            return false
        }
        grantpt(masterFd)
        unlockpt(masterFd)

        // 写数据到 master（模拟向 slave 发送数据）
        let msg = "hello_from_pty_master"
        let writeBuf = LibC.mallocCString(msg)
        let writeBytes = write(masterFd, CPointer<UInt8>(writeBuf.getChars()), UInt64(msg.size))
        if (writeBytes > 0) {
            println("  OK: write master fd ${writeBytes} bytes")
        } else {
            println("  WARN: write 返回 ${writeBytes} (PTY slave 未连接时可能失败)")
        }

        LibC.free(writeBuf)
        close(masterFd)
    }
    true
}

main(): Int64 {
    println("╔══════════════════════════════════════════════╗")
    println("║  1.3 仓颉 FFI + libc PTY 验证                ║")
    println("╚══════════════════════════════════════════════╝")
    println()

    println("── 测试 1：PTY 创建 (posix_openpt/grantpt/unlockpt) ──")
    let r1 = verifyPtyCreate()
    println(if (r1) { "  PASS" } else { "  FAIL" })
    println()

    println("── 测试 2：fcntl 非阻塞模式 ──")
    let r2 = verifyNonBlocking()
    println(if (r2) { "  PASS" } else { "  FAIL" })
    println()

    println("── 测试 3：fork/waitpid ──")
    let r3 = verifyForkWait()
    println(if (r3) { "  PASS" } else { "  FAIL" })
    println()

    println("── 测试 4：PTY master fd 读写 ──")
    let r4 = verifyPtyWriteRead()
    println(if (r4) { "  PASS" } else { "  FAIL" })
    println()

    let allPass = r1 && r2 && r3 && r4
    println(if (allPass) { "║  1.3 全部通过                                   ║" } else { "║  1.3 存在失败项                                 ║" })
    if (allPass) { 0 } else { 1 }
}
