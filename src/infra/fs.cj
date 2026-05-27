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
let LOCK_NB: Int32 = 4
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

/// 带锁读取 JSON 文件。解析失败时返回空对象。
public func readJsonFileAtomic(dataPath: String): JsonValue {
    readJsonFileAtomicInternal(dataPath, false)
}

/// 带锁严格读取 JSON 文件。读取/解析失败时抛出异常。
public func readJsonFileAtomicStrict(dataPath: String): JsonValue {
    readJsonFileAtomicInternal(dataPath, true)
}

private func readJsonFileAtomicInternal(dataPath: String, strict: Bool): JsonValue {
    let lockPath = "${dataPath}.lock"
    unsafe {
        debugTrace("readJsonFileAtomic: start path=${dataPath}")
        let cpath = LibC.mallocCString(lockPath)
        let lockFd = open(cpath, O_CREAT | O_WRONLY, 0o600)
        LibC.free(cpath)
        if (lockFd < 0) {
            debugTrace("readJsonFileAtomic: lock open failed path=${lockPath}")
            if (strict) {
                throw Exception("无法打开配置锁文件: ${lockPath}")
            }
            return JsonObject()
        }
        spinLock(lockFd)

        var content = "{}"
        let dataP = Path(dataPath)
        if (exists(dataP)) {
            let dpath = LibC.mallocCString(dataPath)
            let dataFd = open(dpath, O_RDONLY, 0)
            LibC.free(dpath)
            if (dataFd >= 0) {
                content = fdReadAll(dataFd)
                debugTrace("readJsonFileAtomic: data read path=${dataPath}, size=${content.size}, content=${content}")
                close(dataFd)
            } else {
                debugTrace("readJsonFileAtomic: data open failed path=${dataPath}")
                flock(lockFd, LOCK_UN)
                close(lockFd)
                if (strict) {
                    throw Exception("无法打开 JSON 文件: ${dataPath}")
                }
                return JsonObject()
            }
        } else {
            debugTrace("readJsonFileAtomic: data missing path=${dataPath}")
            flock(lockFd, LOCK_UN)
            close(lockFd)
            if (strict) {
                throw Exception("JSON 文件不存在: ${dataPath}")
            }
            return JsonObject()
        }

        let value = try {
            JsonValue.fromStr(content)
        } catch (e: Exception) {
            flock(lockFd, LOCK_UN)
            close(lockFd)
            if (strict) {
                throw Exception("JSON 解析失败: ${dataPath}: ${e.message}")
            }
            return JsonObject()
        }
        debugTrace("readJsonFileAtomic: parsed success path=${dataPath}")
        flock(lockFd, LOCK_UN)
        close(lockFd)
        value
    }
}

/// 读-修改-写 JSON（全程排他锁，修复 TOCTOU #5）
/// modifier 在锁保护内执行，确保读取和写入之间不被其他进程打断
public func readModifyWriteJson(dataPath: String, modifier: (JsonObject) -> JsonObject): Unit {
    ensureParentDir(dataPath)
    let lockPath = "${dataPath}.lock"
    unsafe {
        let cpath = LibC.mallocCString(lockPath)
        let lockFd = open(cpath, O_CREAT | O_WRONLY, 0o600)
        LibC.free(cpath)
        if (lockFd < 0) { throw Exception("无法创建锁文件: ${lockPath}") }
        spinLock(lockFd)  // ─── 锁开始 ───

        // 1. 读取
        var obj = JsonObject()
        let dataP = Path(dataPath)
        if (exists(dataP)) {
            let dpath = LibC.mallocCString(dataPath)
            let dataFd = open(dpath, O_RDONLY, 0)
            LibC.free(dpath)
            if (dataFd >= 0) {
                let content = fdReadAll(dataFd)
                close(dataFd)
                obj = try { JsonValue.fromStr(content).asObject() } catch (_: Exception) { JsonObject() }
            }
        }

        // 2. 修改
        obj = modifier(obj)

        // 3. 写回
        let newContent = obj.toJsonString()
        let dpath = LibC.mallocCString(dataPath)
        let dataFd = open(dpath, O_CREAT | O_WRONLY, 0o600)
        LibC.free(dpath)
        if (dataFd >= 0) {
            ftruncate(dataFd, 0)
            fdWriteAll(dataFd, newContent)
            fsync(dataFd)
            close(dataFd)
        }

        flock(lockFd, LOCK_UN)  // ─── 锁结束 ───
        close(lockFd)
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
        spinLock(lockFd)

        let content = value.toJsonString()
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

func spinLock(lockFd: Int32): Unit {
    unsafe {
        while (flock(lockFd, LOCK_EX | LOCK_NB) != 0) {
            sleep(50 * Duration.millisecond)
        }
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
