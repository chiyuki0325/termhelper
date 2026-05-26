package termhelper.infra

import stdx.encoding.json.*

public let CURRENT_CONTEXT_VERSION: Int64 = 2

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
    obj.put("shell", JsonString(migrationJsonGetString(old, "shell", envGetShell())))
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
