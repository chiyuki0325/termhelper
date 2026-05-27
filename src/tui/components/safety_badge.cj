package termhelper.tui.components

import termhelper.types.*
import termhelper.i18n.*

public func renderSafetyBadge(info: SafetyInfo): String {
    var out = sectionTitle(uiText("section_safety"))
    out += "  " + safetyMarker(info.level) + " " + safetyLabel(info.level) + "\n"
    for (warning in info.warnings) {
        out += bullet(warning)
    }
    if (info.warnings.size == 0) {
        out += emptyState(uiText("no_safety_warnings"))
    }
    out
}

func safetyLabel(level: SafetyLevel): String {
    match (level) {
        case SafetyLevel.Safe => uiText("safety_safe")
        case SafetyLevel.Caution => uiText("safety_caution")
        case SafetyLevel.Danger => uiText("safety_danger")
        case SafetyLevel.Privilege => uiText("safety_privilege")
    }
}

func safetyMarker(level: SafetyLevel): String {
    match (level) {
        case SafetyLevel.Safe => "[+]"
        case SafetyLevel.Caution => "[!]"
        case SafetyLevel.Danger => "[!!]"
        case SafetyLevel.Privilege =>
            if (isChinese()) {
                "[锁]"
            } else {
                "[root]"
            }
    }
}
