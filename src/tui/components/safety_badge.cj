package termhelper.tui.components

import termhelper.types.*

public func renderSafetyBadge(info: SafetyInfo): String {
    var out = sectionTitle("安全性")
    out += "  " + safetyMarker(info.level) + " " + safetyLabel(info.level) + "\n"
    for (warning in info.warnings) {
        out += bullet(warning)
    }
    if (info.warnings.size == 0) {
        out += emptyState("没有安全警告。")
    }
    out
}

func safetyLabel(level: SafetyLevel): String {
    match (level) {
        case SafetyLevel.Safe => "安全"
        case SafetyLevel.Caution => "注意"
        case SafetyLevel.Danger => "危险"
        case SafetyLevel.Privilege => "提权"
    }
}

func safetyMarker(level: SafetyLevel): String {
    match (level) {
        case SafetyLevel.Safe => "[+]"
        case SafetyLevel.Caution => "[!]"
        case SafetyLevel.Danger => "[!!]"
        case SafetyLevel.Privilege => "[锁]"
    }
}
