package termhelper.infra

import stdx.encoding.json.*

public let CURRENT_CONTEXT_VERSION: Int64 = 4

/// Migrate a persisted context object to CURRENT_CONTEXT_VERSION.
/// Returns None when the file is from a newer unsupported version or is invalid.
public func migrateContextJson(value: JsonValue): ?JsonObject {
    try {
        var obj = value.asObject()
        var version = migrationJsonGetInt(obj, "version", 1)
        if (version > CURRENT_CONTEXT_VERSION) {
            return None
        }
        while (version < CURRENT_CONTEXT_VERSION) {
            if (version == 1) {
                obj = migrateV1ToV2(obj)
                version = 2
            } else if (version == 2) {
                obj = migrateV2ToV3(obj)
                version = 3
            } else if (version == 3) {
                obj = migrateV3ToV4(obj)
                version = 4
            } else {
                return None
            }
        }
        Some(obj)
    } catch (_: Exception) {
        None
    }
}

/// v1 -> v2 adds extras and lastUpdated defaults and normalizes field names.
func migrateV1ToV2(old: JsonObject): JsonObject {
    let obj = JsonObject()
    obj.put("version", JsonInt(2))
    obj.put("os", jsonGetOrNullString(old, "os"))
    obj.put("distro", jsonGetOrNullString(old, "distro"))
    match (old.get("packageManager")) {
        case Some(v) => obj.put("packageManager", v)
        case None => match (old.get("package_manager")) {
            case Some(v2) => obj.put("packageManager", v2)
            case None => obj.put("packageManager", JsonString(""))
        }
    }
    obj.put("shell", JsonString(migrationJsonGetString(old, "shell", "")))
    match (old.get("tools")) {
        case Some(v) => obj.put("tools", v)
        case None => obj.put("tools", JsonObject())
    }
    match (old.get("extras")) {
        case Some(v) => obj.put("extras", v)
        case None => obj.put("extras", JsonObject())
    }
    match (old.get("lastUpdated")) {
        case Some(v) => obj.put("lastUpdated", v)
        case None => match (old.get("last_updated")) {
            case Some(v2) => obj.put("lastUpdated", v2)
            case None => obj.put("lastUpdated", JsonInt(0))
        }
    }
    obj
}

/// v2 -> v3 adds natural-language environment facts keyed by stable IDs.
func migrateV2ToV3(old: JsonObject): JsonObject {
    let obj = JsonObject()
    obj.put("version", JsonInt(3))
    obj.put("os", jsonGetOrNullString(old, "os"))
    obj.put("distro", jsonGetOrNullString(old, "distro"))
    match (old.get("packageManager")) {
        case Some(v) => obj.put("packageManager", v)
        case None => obj.put("packageManager", JsonString(""))
    }
    obj.put("shell", JsonString(migrationJsonGetString(old, "shell", "")))
    match (old.get("tools")) {
        case Some(v) => obj.put("tools", v)
        case None => obj.put("tools", JsonObject())
    }
    match (old.get("extras")) {
        case Some(v) => obj.put("extras", v)
        case None => obj.put("extras", JsonObject())
    }
    match (old.get("lastUpdated")) {
        case Some(v) => obj.put("lastUpdated", v)
        case None => obj.put("lastUpdated", JsonInt(0))
    }
    obj.put("facts", buildFactsFromV2(old))
    obj
}

/// v3 -> v4 keeps only facts + lastUpdated as the persisted environment model.
/// Shell is deliberately excluded because it is injected dynamically into prompts.
func migrateV3ToV4(old: JsonObject): JsonObject {
    let obj = JsonObject()
    obj.put("version", JsonInt(4))
    obj.put("lastUpdated", match (old.get("lastUpdated")) {
        case Some(v) => v
        case None => JsonInt(0)
    })
    obj.put("facts", buildFactsFromLegacyObject(old))
    obj
}

func buildFactsFromLegacyObject(old: JsonObject): JsonObject {
    let facts = match (old.get("facts")) {
        case Some(v) => match (v.kind()) {
            case JsObject => v.asObject()
            case _ => JsonObject()
        }
        case None => JsonObject()
    }
    let ts = migrationJsonGetInt(old, "lastUpdated", 0)

    let os = migrationJsonGetString(old, "os", "")
    if (os.size > 0 && !facts.containsKey("os.uname")) {
        facts.put("os.uname", factJson("当前系统内核名称是 ${os}。", "migrated context.os", ts))
    }

    let distro = migrationJsonGetString(old, "distro", "")
    if (distro.size > 0 && !facts.containsKey("distro.current")) {
        facts.put("distro.current", factJson("当前系统发行版 ID 是 ${distro}。", "migrated context.distro", ts))
    }

    let packageManager = migrationJsonGetString(old, "packageManager", "")
    if (packageManager.size > 0) {
        let id = "packageManager.${migrationFactIdSuffix(packageManager)}"
        if (!facts.containsKey(id)) {
            facts.put(id, factJson("当前记录的包管理器是 ${packageManager}。", "migrated context.packageManager", ts))
        }
    }

    facts
}

func buildFactsFromV2(old: JsonObject): JsonObject {
    let facts = JsonObject()
    let ts = migrationJsonGetInt(old, "lastUpdated", 0)
    let distro = migrationJsonGetString(old, "distro", "")
    if (distro.size > 0) {
        facts.put("distro.current", factJson("当前系统发行版 ID 是 ${distro}。", "migrated context.distro", ts))
    }
    let packageManager = migrationJsonGetString(old, "packageManager", "")
    if (packageManager.size > 0) {
        let id = "packageManager.${migrationFactIdSuffix(packageManager)}"
        facts.put(
            id,
            factJson("当前记录的包管理器是 ${packageManager}。", "migrated context.packageManager", ts)
        )
    }
    facts
}

func migrationFactIdSuffix(raw: String): String {
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

func factJson(text: String, source: String, lastVerified: Int64): JsonObject {
    let obj = JsonObject()
    obj.put("text", JsonString(text))
    obj.put("source", JsonString(source))
    obj.put("lastVerified", JsonInt(lastVerified))
    obj
}

func jsonGetOrNullString(obj: JsonObject, key: String): JsonValue {
    match (obj.get(key)) {
        case Some(v) => v
        case None => JsonString("")
    }
}

func migrationJsonGetString(obj: JsonObject, key: String, default: String): String {
    match (obj.get(key)) {
        case Some(jv) => match (jv.kind()) {
            case JsString => jv.asString().getValue()
            case _ => default
        }
        case None => default
    }
}

func migrationJsonGetInt(obj: JsonObject, key: String, default: Int64): Int64 {
    match (obj.get(key)) {
        case Some(jv) => match (jv.kind()) {
            case JsInt => jv.asInt().getValue()
            case _ => default
        }
        case None => default
    }
}
