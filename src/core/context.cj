package termhelper.core

import termhelper.types.*
import termhelper.infra.*
import std.collection.*
import stdx.encoding.json.*

foreign func time(tloc: CPointer<Int64>): Int64

public class ContextManager {
    public init() {}

    public func load(): EnvironmentContext {
        let contextPath = termhelperContextPath()
        if (fileExists(contextPath)) {
            let raw = loadContextJson()
            match (migrateContextJson(raw)) {
                case Some(obj) =>
                    let ctx = contextFromJson(obj)
                    if (ctx.version < CURRENT_CONTEXT_VERSION) {
                        let fresh = detectEnvironment()
                        save(fresh)
                        fresh
                    } else {
                        save(ctx)
                        ctx
                    }
                case None =>
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
            writeFileString(contextPath, contextToJson(ctx).toString())
        } catch (e: Exception) {
            debugTrace("ContextManager.save: skip persist path=${contextPath}, err=${e.message}")
        }
    }

    /// Merge JSON object fields into extras/tools for investigation results.
    public func update(ctx: EnvironmentContext, delta: JsonObject): EnvironmentContext {
        let tools = cloneMap(ctx.tools)
        let extras = cloneMap(ctx.extras)

        match (delta.get("tools")) {
            case Some(toolsJv) => mergeStringObject(tools, toolsJv.asObject())
            case None => ()
        }
        match (delta.get("extras")) {
            case Some(extrasJv) => mergeStringObject(extras, extrasJv.asObject())
            case None => mergeStringObject(extras, delta)
        }

        EnvironmentContext(
            CURRENT_CONTEXT_VERSION,
            ctx.os,
            ctx.distro,
            ctx.packageManager,
            ctx.shell,
            tools,
            extras,
            currentTimeSeconds()
        )
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

    EnvironmentContext(
        CURRENT_CONTEXT_VERSION,
        os,
        distro,
        packageManager,
        shell,
        tools,
        extras,
        currentTimeSeconds()
    )
}

public func contextToJson(ctx: EnvironmentContext): JsonObject {
    let obj = JsonObject()
    obj.put("version", JsonInt(ctx.version))
    obj.put("os", JsonString(optionString(ctx.os)))
    obj.put("distro", JsonString(optionString(ctx.distro)))
    obj.put("packageManager", JsonString(optionString(ctx.packageManager)))
    obj.put("shell", JsonString(ctx.shell))
    obj.put("tools", stringMapToJson(ctx.tools))
    obj.put("extras", stringMapToJson(ctx.extras))
    obj.put("lastUpdated", JsonInt(ctx.lastUpdated))
    obj
}

public func contextFromJson(obj: JsonObject): EnvironmentContext {
    EnvironmentContext(
        jsonGetInt(obj, "version", 1),
        nonEmptyOption(jsonGetString(obj, "os", "")),
        nonEmptyOption(jsonGetString(obj, "distro", "")),
        nonEmptyOption(jsonGetString(obj, "packageManager", "")),
        jsonGetString(obj, "shell", envGetShell()),
        jsonObjectToStringMap(getObject(obj, "tools")),
        jsonObjectToStringMap(getObject(obj, "extras")),
        jsonGetInt(obj, "lastUpdated", 0)
    )
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

func loadContextJson(): JsonValue {
    let raw = readFileString(termhelperContextPath())
    try {
        JsonValue.fromStr(raw)
    } catch (_: Exception) {
        JsonObject()
    }
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

func optionString(v: ?String): String {
    match (v) {
        case Some(s) => s
        case None => ""
    }
}

func stringMapToJson(map: HashMap<String, String>): JsonObject {
    let obj = JsonObject()
    for ((k, v) in map) { obj.put(k, JsonString(v)) }
    obj
}

func jsonObjectToStringMap(obj: JsonObject): HashMap<String, String> {
    let map = HashMap<String, String>()
    for ((k, v) in obj.getFields()) {
        match (v.kind()) {
            case JsString => map.add(k, v.asString().getValue())
            case _ => map.add(k, v.toJsonString())
        }
    }
    map
}

func cloneMap(src: HashMap<String, String>): HashMap<String, String> {
    let dst = HashMap<String, String>()
    for ((k, v) in src) { dst.add(k, v) }
    dst
}

func mergeStringObject(dst: HashMap<String, String>, obj: JsonObject): Unit {
    for ((k, v) in obj.getFields()) {
        match (v.kind()) {
            case JsString => dst.add(k, v.asString().getValue())
            case _ => dst.add(k, v.toJsonString())
        }
    }
}

func getObject(obj: JsonObject, key: String): JsonObject {
    match (obj.get(key)) {
        case Some(jv) => try { jv.asObject() } catch (_: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

func jsonGetString(obj: JsonObject, key: String, default: String): String {
    match (obj.get(key)) {
        case Some(jv) => match (jv.kind()) {
            case JsString => jv.asString().getValue()
            case _ => default
        }
        case None => default
    }
}

func jsonGetInt(obj: JsonObject, key: String, default: Int64): Int64 {
    match (obj.get(key)) {
        case Some(jv) => match (jv.kind()) {
            case JsInt => jv.asInt().getValue()
            case _ => default
        }
        case None => default
    }
}
