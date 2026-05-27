package termhelper.tui

import termhelper.types.*

public func safetyLabel(level: SafetyLevel): String {
    match (level) {
        case SafetyLevel.Safe => "安全"
        case SafetyLevel.Caution => "注意"
        case SafetyLevel.Danger => "危险"
        case SafetyLevel.Privilege => "提权"
    }
}

public func safetyMarker(level: SafetyLevel): String {
    match (level) {
        case SafetyLevel.Safe => "[+]"
        case SafetyLevel.Caution => "[!]"
        case SafetyLevel.Danger => "[!!]"
        case SafetyLevel.Privilege => "[锁]"
    }
}

public func errorLabel(): String { "错误" }
public func successLabel(): String { "完成" }
