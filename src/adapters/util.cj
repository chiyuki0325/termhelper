package termhelper.adapters

import stdx.encoding.json.*

// ═══════════════════════════════════════════════════════════════
// 共享工具函数 — 被各 Provider 和 SSE 解析器使用
// ═══════════════════════════════════════════════════════════════

/// 从 JsonObject 安全获取字符串值
func jsonGetString(obj: JsonObject, key: String, default: String): String {
    match (obj.get(key)) {
        case Some(jv) => match (jv.kind()) {
            case JsString => jv.asString().getValue();
            case _ => default
        }
        case None => default
    }
}

/// 从 JsonObject 安全获取整数值
func jsonGetInt(obj: JsonObject, key: String, default: Int64): Int64 {
    match (obj.get(key)) {
        case Some(jv) => match (jv.kind()) {
            case JsInt => jv.asInt().getValue();
            case _ => default
        }
        case None => default
    }
}

/// 从 JsonObject 安全获取布尔值
func jsonGetBool(obj: JsonObject, key: String, default: Bool): Bool {
    match (obj.get(key)) {
        case Some(jv) => match (jv.kind()) {
            case JsBool => jv.asBool().getValue();
            case _ => default
        }
        case None => default
    }
}

/// 去除字符串前缀（若存在），否则返回原字符串
func stripPrefix(s: String, prefix: String): String {
    if (s.startsWith(prefix)) {
        s[prefix.size..]
    } else {
        s
    }
}
