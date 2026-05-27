package termhelper.infra

// ═══════════════════════════════════════════════════════════════
// 公共工具 — 环境变量 + 字符串 + 通用 FFI 声明
// ═══════════════════════════════════════════════════════════════

// ── 环境变量 FFI ──

foreign func getenv(name: CString): CPointer<Int8>

var debugTraceEnabled: Bool = false

public func enableDebugTrace(): Unit {
    debugTraceEnabled = true
}

public func debugTrace(message: String): Unit {
    if (debugTraceEnabled || envGetOrDefault("TERMHELPER_TRACE", "") == "1") {
        eprintln("[termhelper-trace] ${message}")
    }
}

public func envGet(name: String): ?String {
    unsafe {
        let cname = LibC.mallocCString(name)
        let ptr = getenv(cname)
        LibC.free(cname)
        if (ptr.isNull()) {
            None
        } else {
            let cstr = CString(CPointer<UInt8>(ptr))
            Some(cstr.toString())
        }
    }
}

public func envGetOrDefault(name: String, default: String): String {
    match (envGet(name)) {
        case Some(v) => v
        case None => default
    }
}

public func envGetHome(): String { envGetOrDefault("HOME", "/home") }
public func envGetShell(): String { envGetOrDefault("SHELL", "/bin/bash") }

// ── 通用 FFI 声明（整个 infra 包共享）──

foreign func close(fd: Int32): Int32
foreign func write(fd: Int32, buf: CPointer<UInt8>, count: UInt64): Int64
foreign func read(fd: Int32, buf: CPointer<UInt8>, count: UInt64): Int64
foreign func open(path: CString, flags: Int32, mode: Int32): Int32
foreign func flock(fd: Int32, operation: Int32): Int32
foreign func fsync(fd: Int32): Int32
foreign func ftruncate(fd: Int32, length: Int64): Int32
foreign func fork(): Int32
foreign func waitpid(pid: Int32, status: CPointer<Int32>, options: Int32): Int32
foreign func _exit(status: Int32): Unit
foreign func dup2(oldfd: Int32, newfd: Int32): Int32
foreign func kill(pid: Int32, sig: Int32): Int32

let SIGTERM: Int32 = 15
let SIGKILL: Int32 = 9

// ── 字符串工具 ──

public func strContains(haystack: String, needle: String): Bool {
    strFind(haystack, needle) >= 0
}

public func strFind(haystack: String, needle: String): Int64 {
    if (needle.size == 0) { return 0 }
    if (needle.size > haystack.size) { return -1 }
    for (i in 0..(haystack.size - needle.size + 1)) {
        var found = true
        for (j in 0..needle.size) {
            if (haystack[i + j] != needle[j]) {
                found = false
                break
            }
        }
        if (found) { return i }
    }
    -1
}

// ── 读取 fd 全部内容 ──

public func fdReadAll(fd: Int32): String {
    unsafe {
        var result = ""
        let buf = LibC.malloc<UInt8>(count: 4096)
        var n = read(fd, buf, 4096)
        while (n > 0) {
            for (i in 0..n) {
                result += String(Rune(Int32(buf.read(i))))
            }
            n = read(fd, buf, 4096)
        }
        LibC.free(buf)
        result
    }
}

public func fdWriteAll(fd: Int32, content: String): Bool {
    unsafe {
        let bytes = content.toArray()
        let writeBuf = LibC.malloc<UInt8>(count: bytes.size)
        for (i in 0..bytes.size) { writeBuf.write(i, bytes[i]) }
        let written = write(fd, writeBuf, UInt64(bytes.size))
        LibC.free(writeBuf)
        written >= 0
    }
}
