package termhelper.tui

import termhelper.types.*

public func safetyLabel(level: SafetyLevel): String {
    match (level) {
        case SafetyLevel.Safe => "SAFE"
        case SafetyLevel.Caution => "CAUTION"
        case SafetyLevel.Danger => "DANGER"
        case SafetyLevel.Privilege => "PRIVILEGE"
    }
}

public func safetyMarker(level: SafetyLevel): String {
    match (level) {
        case SafetyLevel.Safe => "[+]"
        case SafetyLevel.Caution => "[!]"
        case SafetyLevel.Danger => "[!!]"
        case SafetyLevel.Privilege => "[LOCK]"
    }
}

public func errorLabel(): String { "ERROR" }
public func successLabel(): String { "OK" }
