package termhelper.core

import termhelper.types.*
import termhelper.infra.*
import std.collection.*
import stdx.encoding.json.*
import stdx.serialization.serialization.*

foreign func time(tloc: CPointer<Int64>): Int64

public class ContextManager {
    public init() {}

    public func load(): EnvironmentContext {
        let contextPath = termhelperContextPath()
        if (fileExists(contextPath)) {
            match (loadAndMigrate()) {
                case Some(ctx) =>
                    if (ctx.version < CURRENT_CONTEXT_VERSION) {
                        let fresh = detectEnvironment()
                        save(fresh)
                        fresh
                    } else {
                        save(ctx)
                        ctx
                    }
                case None =>
                    // 文件损坏或版本不兼容 — 丢弃并重新探测
                    let fresh = detectEnvironment()
                    save(fresh)
                    fresh
            }
        } else {
            let fresh = detectEnvironment()
            save(fresh)
            fresh
        }
    }

    public func save(ctx: EnvironmentContext): Unit {
        let contextPath = termhelperContextPath()
        try {
            let dm = ctx.serialize()
            let jsonStr = dm.toJson().toJsonString()
            writeFileString(contextPath, jsonStr)
        } catch (e: Exception) {
            debugTrace("ContextManager.save: skip persist path=${contextPath}, err=${e.message}")
        }
    }

    /// 合并调查结论到环境上下文。
    /// delta 来自 InvestigateData.contextUpdates。
    public func update(ctx: EnvironmentContext, delta: HashMap<String, String>): EnvironmentContext {
        let tools = cloneMap(ctx.tools)
        let extras = cloneMap(ctx.extras)

        for ((k, v) in delta) {
            extras[k] = v
        }

        let newCtx = EnvironmentContext()
        newCtx.version = CURRENT_CONTEXT_VERSION
        newCtx.os = ctx.os
        newCtx.distro = ctx.distro
        newCtx.packageManager = ctx.packageManager
        newCtx.shell = ctx.shell
        newCtx.tools = tools
        newCtx.extras = extras
        newCtx.lastUpdated = currentTimeSeconds()
        newCtx
    }
}

/// 读取 context.json → 迁移 → 返回 EnvironmentContext。
/// 文件缺失/JSON 损坏/版本过高 → None
func loadAndMigrate(): ?EnvironmentContext {
    let raw = readFileString(termhelperContextPath())
    let jv = try { JsonValue.fromStr(raw) } catch (_: Exception) { return None }
    match (migrateContextJson(jv)) {
        case Some(obj) =>
            try {
                let dm = DataModel.fromJson(obj)
                Some(EnvironmentContext.deserialize(dm))
            } catch (_: Exception) { None }
        case None => None
    }
}

public func detectEnvironment(): EnvironmentContext {
    let shell = envGetShell()
    let os = nonEmptyOption(runAndTrim("uname -s"))
    let distro = detectDistro()
    let packageManager = detectPackageManager()
    let tools = HashMap<String, String>()
    let extras = HashMap<String, String>()

    let candidates = ["bash", "zsh", "fish", "nu", "git", "docker", "kubectl", "systemctl", "sudo"]
    for (tool in candidates) {
        let path = runAndTrim("command -v ${tool}")
        if (path.size > 0) { tools.add(tool, path) }
    }

    let ctx = EnvironmentContext()
    ctx.version = CURRENT_CONTEXT_VERSION
    ctx.os = os
    ctx.distro = distro
    ctx.packageManager = packageManager
    ctx.shell = shell
    ctx.tools = tools
    ctx.extras = extras
    ctx.lastUpdated = currentTimeSeconds()
    ctx
}

func detectDistro(): ?String {
    let id = runAndTrim("grep '^ID=' /etc/os-release | head -n1 | cut -d= -f2")
    nonEmptyOption(id.replace("\"", ""))
}

func detectPackageManager(): ?String {
    let candidates = ["apt-get", "dnf", "yum", "pacman", "zypper", "apk", "emerge", "nix"]
    for (pm in candidates) {
        let path = runAndTrim("command -v ${pm}")
        if (path.size > 0) { return Some(pm) }
    }
    None
}

func runAndTrim(command: String): String {
    let (code, stdout) = spawnSimple(command)
    if (code == 0) { stdout.trimAscii() } else { "" }
}

func currentTimeSeconds(): Int64 {
    unsafe { time(CPointer<Int64>()) }
}

func nonEmptyOption(s: String): ?String {
    let trimmed = s.trimAscii()
    if (trimmed.size > 0) { Some(trimmed) } else { None }
}

func cloneMap(src: HashMap<String, String>): HashMap<String, String> {
    let dst = HashMap<String, String>()
    for ((k, v) in src) { dst.add(k, v) }
    dst
}
