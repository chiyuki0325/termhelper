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
            writeJsonFileAtomic(contextPath, dm.toJson())
        } catch (e: Exception) {
            debugTrace("ContextManager.save: skip persist path=${contextPath}, err=${e.message}")
        }
    }

    /// 合并调查结论到环境上下文。
    /// delta 来自 InvestigateData.contextUpdates。
    public func update(ctx: EnvironmentContext, delta: HashMap<String, String>): EnvironmentContext {
        let newCtx = cloneContext(ctx)
        let now = currentTimeSeconds()
        for ((k, v) in delta) {
            let id = "legacy.${sanitizeFactId(k)}"
            newCtx.facts.add(id, makeFact(v, "legacy contextUpdates.${k}", now))
        }
        newCtx.lastUpdated = now
        newCtx
    }

    public func applyFactEdits(
        ctx: EnvironmentContext,
        edits: ArrayList<FactEdit>,
        allowedSources: ArrayList<String>
    ): EnvironmentContext {
        let newCtx = cloneContext(ctx)
        var changed = false
        let now = currentTimeSeconds()

        for (edit in edits) {
            if (!isValidFactId(edit.id)) {
                debugTrace("ContextManager.applyFactEdits: reject invalid id=${edit.id}")
                continue
            }
            if (!isAllowedFactSource(edit.source, allowedSources)) {
                debugTrace("ContextManager.applyFactEdits: reject source=${edit.source}")
                continue
            }

            if (edit.op == "add") {
                if (edit.newText.trimAscii().size == 0 || newCtx.facts.contains(edit.id)) {
                    debugTrace("ContextManager.applyFactEdits: reject add id=${edit.id}")
                    continue
                }
                newCtx.facts.add(edit.id, makeFact(edit.newText, edit.source, now))
                changed = true
            } else if (edit.op == "update") {
                match (newCtx.facts.get(edit.id)) {
                    case Some(existing) =>
                        if (edit.oldText != existing.text || edit.newText.trimAscii().size == 0) {
                            debugTrace("ContextManager.applyFactEdits: reject update id=${edit.id}")
                            continue
                        }
                        newCtx.facts.add(edit.id, makeFact(edit.newText, edit.source, now))
                        changed = true
                    case None => debugTrace("ContextManager.applyFactEdits: reject missing update id=${edit.id}")
                }
            } else if (edit.op == "delete") {
                match (newCtx.facts.get(edit.id)) {
                    case Some(existing) =>
                        if (edit.oldText != existing.text) {
                            debugTrace("ContextManager.applyFactEdits: reject delete id=${edit.id}")
                            continue
                        }
                        newCtx.facts.remove(edit.id)
                        changed = true
                    case None => debugTrace("ContextManager.applyFactEdits: reject missing delete id=${edit.id}")
                }
            } else {
                debugTrace("ContextManager.applyFactEdits: reject op=${edit.op}")
            }
        }

        if (changed) {
            newCtx.lastUpdated = now
        }
        newCtx
    }
}

/// 读取 context.json → 迁移 → 返回 EnvironmentContext。
/// 文件缺失/JSON 损坏/版本过高 → None
func loadAndMigrate(): ?EnvironmentContext {
    let jv = try { readJsonFileAtomicStrict(termhelperContextPath()) } catch (_: Exception) { return None }
    match (migrateContextJson(jv)) {
        case Some(obj) =>
            try {
                let dm = DataModel.fromJson(obj)
                let ctx = EnvironmentContext.deserialize(dm)
                Some(normalizeEnvironmentContext(ctx))
            } catch (_: Exception) { None }
        case None => None
    }
}

func normalizeEnvironmentContext(ctx: EnvironmentContext): EnvironmentContext {
    ctx.version = CURRENT_CONTEXT_VERSION
    match (ctx.facts.get("shell.current")) {
        case Some(_) => ctx.facts.remove("shell.current")
        case None => ()
    }
    ctx
}

public func detectEnvironment(): EnvironmentContext {
    let os = nonEmptyOption(runAndTrim("uname -s"))
    let distro = detectDistro()
    let packageManagers = detectPackageManagers()
    let tools = HashMap<String, String>()

    let candidates = ["bash", "zsh", "fish", "nu", "git", "docker", "kubectl", "systemctl", "sudo"]
    for (tool in candidates) {
        let path = runAndTrim("command -v ${tool}")
        if (path.size > 0) { tools.add(tool, path) }
    }

    let ctx = EnvironmentContext()
    ctx.version = CURRENT_CONTEXT_VERSION
    ctx.facts = factsFromDetectedEnvironment(os, distro, packageManagers, tools)
    ctx.lastUpdated = currentTimeSeconds()
    ctx
}

func detectDistro(): ?String {
    let id = runAndTrim("grep '^ID=' /etc/os-release | head -n1 | cut -d= -f2")
    nonEmptyOption(id.replace("\"", ""))
}

func detectPackageManagers(): HashMap<String, String> {
    let found = HashMap<String, String>()
    let candidates = [
        "rpm-ostree", "swupd", "xbps-install", "eopkg", "guix", "nix", "home-manager", "emerge", "apk",
        "zypper", "dnf", "yum", "pacman", "oma", "flatpak", "snap", "apt", "apt-get"
    ]
    for (pm in candidates) {
        let path = runAndTrim("command -v ${pm}")
        if (path.size > 0) { found.add(pm, path) }
    }
    found
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

func cloneFacts(src: HashMap<String, EnvironmentFact>): HashMap<String, EnvironmentFact> {
    let dst = HashMap<String, EnvironmentFact>()
    for ((k, v) in src) {
        dst.add(k, makeFact(v.text, v.source, v.lastVerified))
    }
    dst
}

func cloneContext(ctx: EnvironmentContext): EnvironmentContext {
    let newCtx = EnvironmentContext()
    newCtx.version = CURRENT_CONTEXT_VERSION
    newCtx.facts = cloneFacts(ctx.facts)
    newCtx.lastUpdated = ctx.lastUpdated
    newCtx
}

func makeFact(text: String, source: String, lastVerified: Int64): EnvironmentFact {
    let fact = EnvironmentFact()
    fact.text = text
    fact.source = source
    fact.lastVerified = lastVerified
    fact
}

func factsFromDetectedEnvironment(
    os: ?String,
    distro: ?String,
    packageManagers: HashMap<String, String>,
    tools: HashMap<String, String>
): HashMap<String, EnvironmentFact> {
    let facts = HashMap<String, EnvironmentFact>()
    let now = currentTimeSeconds()
    match (os) {
        case Some(v) => facts.add("os.uname", makeFact("当前系统内核名称是 ${v}。", "initial local detection: uname -s", now))
        case None => ()
    }
    match (distro) {
        case Some(v) => facts.add("distro.current", makeFact("当前系统发行版 ID 是 ${v}。", "initial local detection: /etc/os-release ID", now))
        case None => ()
    }
    for ((name, path) in packageManagers) {
        facts.add("packageManager.${name}", makeFact("系统中存在包管理器 ${name}，路径是 ${path}。", "initial local detection: command -v ${name}", now))
    }
    for ((name, path) in tools) {
        facts.add("tool.${name}", makeFact("系统中存在 ${name}，路径是 ${path}。", "initial local detection: command -v ${name}", now))
    }
    facts
}

func sanitizeFactId(raw: String): String {
    var out = ""
    for (i in 0..raw.size) {
        let b = raw[i]
        let ok = (b >= b'a' && b <= b'z') || (b >= b'A' && b <= b'Z') || (b >= b'0' && b <= b'9') ||
            b == b'.' || b == b'_' || b == b'-'
        if (ok) {
            out += String(Rune(Int32(b)))
        } else {
            out += "_"
        }
    }
    if (out.size == 0) { "unknown" } else { out }
}

func isValidFactId(id: String): Bool {
    if (id.size == 0 || id.size > 120) {
        return false
    }
    for (i in 0..id.size) {
        let b = id[i]
        let ok = (b >= b'a' && b <= b'z') || (b >= b'A' && b <= b'Z') || (b >= b'0' && b <= b'9') ||
            b == b'.' || b == b'_' || b == b'-'
        if (!ok) {
            return false
        }
    }
    true
}

func isAllowedFactSource(source: String, allowedSources: ArrayList<String>): Bool {
    if (source.size == 0 || allowedSources.size == 0) {
        return false
    }
    for (cmd in allowedSources) {
        if (source == cmd) {
            return true
        }
    }
    false
}
