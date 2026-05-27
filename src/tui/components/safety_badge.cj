package termhelper.tui.components

import termhelper.types.*

public func renderSafetyBadge(info: SafetyInfo): String {
    var out = "Safety: ${safetyMarker(info.level)} ${safetyLabel(info.level)}\n"
    for (warning in info.warnings) {
        out += "  - ${warning}\n"
    }
    out
}

func safetyLabel(level: SafetyLevel): String {
    match (level) {
        case SafetyLevel.Safe => "SAFE"
        case SafetyLevel.Caution => "CAUTION"
        case SafetyLevel.Danger => "DANGER"
        case SafetyLevel.Privilege => "PRIVILEGE"
    }
}

func safetyMarker(level: SafetyLevel): String {
    match (level) {
        case SafetyLevel.Safe => "[+]"
        case SafetyLevel.Caution => "[!]"
        case SafetyLevel.Danger => "[!!]"
        case SafetyLevel.Privilege => "[LOCK]"
    }
}
