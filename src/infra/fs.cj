package termhelper.infra

import std.fs.*
import std.io.*
import stdx.encoding.json.*

// ═══════════════════════════════════════════════════════════════
// 文件工具 — JSON 原子读写 + flock 排他锁
// 依赖 util.cj 中的 FFI 声明 (open/close/read/write/flock/fsync/ftruncate)
// ═══════════════════════════════════════════════════════════════

let O_RDONLY: Int32 = 0
let O_WRONLY: Int32 = 1
let O_CREAT: Int32 = 0o100
let LOCK_EX: Int32 = 2
let LOCK_UN: Int32 = 8

/// 确保文件所在目录存在
func ensureParentDir(filePath: String): Unit {
    var lastSep: Int64 = -1
    for (i in 0..filePath.size) {
        if (filePath[i] == b'/') { lastSep = i }
    }
    if (lastSep > 0) {
        let dirPath = filePath[0..lastSep]
        let p = Path(dirPath)
        if (!exists(p)) {
            Directory.create(p, recursive: true)
        }
    }
}

/// 带锁读取 JSON 文件
public func readJsonFileAtomic(dataPath: String): JsonValue {
    let lockPath = "${dataPath}.lock"
    unsafe {
        let cpath = LibC.mallocCString(lockPath)
        let lockFd = open(cpath, O_CREAT | O_WRONLY, 0o600)
        LibC.free(cpath)
        if (lockFd < 0) { return JsonObject() }
        flock(lockFd, LOCK_EX)

        var content = "{}"
        let dataP = Path(dataPath)
        if (exists(dataP)) {
            let dpath = LibC.mallocCString(dataPath)
            let dataFd = open(dpath, O_RDONLY, 0)
            LibC.free(dpath)
            if (dataFd >= 0) {
                content = fdReadAll(dataFd)
                close(dataFd)
            }
        }

        let value = try { JsonValue.fromStr(content) } catch (_: Exception) { JsonObject() }
        flock(lockFd, LOCK_UN)
        close(lockFd)
        value
    }
}

/// 带锁写入 JSON 文件（排他锁 + fsync）
public func writeJsonFileAtomic(dataPath: String, value: JsonValue): Unit {
    ensureParentDir(dataPath)
    let lockPath = "${dataPath}.lock"
    unsafe {
        let cpath = LibC.mallocCString(lockPath)
        let lockFd = open(cpath, O_CREAT | O_WRONLY, 0o600)
        LibC.free(cpath)
        if (lockFd < 0) { throw Exception("无法创建锁文件: ${lockPath}") }
        flock(lockFd, LOCK_EX)

        let content = value.toString()
        let dpath = LibC.mallocCString(dataPath)
        let dataFd = open(dpath, O_CREAT | O_WRONLY, 0o600)
        LibC.free(dpath)
        if (dataFd < 0) {
            flock(lockFd, LOCK_UN); close(lockFd)
            throw Exception("无法打开数据文件: ${dataPath}")
        }
        ftruncate(dataFd, 0)
        fdWriteAll(dataFd, content)
        fsync(dataFd); close(dataFd)
        flock(lockFd, LOCK_UN); close(lockFd)
    }
}

/// 读取文件全部内容为字符串（使用 std.fs API）
public func readFileString(path: String): String {
    let data = File.readFrom(Path(path))
    String.fromUtf8(data)
}

/// 写入字符串到文件（使用 std.fs API）
public func writeFileString(path: String, content: String): Unit {
    ensureParentDir(path)
    try (f = File(Path(path), Write)) {
        f.write(content.toArray())
    }
}

/// 检查文件是否存在
public func fileExists(path: String): Bool {
    exists(Path(path))
}
