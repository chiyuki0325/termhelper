package termhelper.tui

import termhelper.types.*
import termhelper.i18n.*

public func safetyLabel(level: SafetyLevel): String {
    match (level) {
        case SafetyLevel.Safe => uiText("safety_safe")
        case SafetyLevel.Caution => uiText("safety_caution")
        case SafetyLevel.Danger => uiText("safety_danger")
        case SafetyLevel.Privilege => uiText("safety_privilege")
    }
}

public func safetyMarker(level: SafetyLevel): String {
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

public func errorLabel(): String {
    uiText("error_title")
}

public func successLabel(): String {
    uiText("status_done")
}
