package termhelper.core

import termhelper.types.*
import std.collection.*

public func applySafetyFallback(resp: LLMResponse): LLMResponse {
    match (resp) {
        case LLMResponse.Command(data) => LLMResponse.Command(applyCommandSafetyFallback(data))
        case _ => resp
    }
}

func applyCommandSafetyFallback(data: CommandData): CommandData {
    let current = data.safety.level
    let shouldScan = match (current) {
        case SafetyLevel.Safe => true
        case SafetyLevel.Caution => true
        case _ => false
    }
    if (!shouldScan) { return data }

    let warnings = ArrayList<String>()
    for (i in 0..data.safety.warnings.size) { warnings.add(data.safety.warnings[i]) }

    if (containsDanger(data.command)) {
        warnings.add("本地安全兜底检测到潜在破坏性命令，请逐项确认路径、通配符和递归参数。")
        var newData = CommandData()
        newData.command = data.command
        newData.explanation = data.explanation
        newData.interactive = data.interactive
        newData.safety.level = SafetyLevel.Danger
        newData.safety.warnings = warnings
        return newData
    }

    if (containsPrivilege(data.command)) {
        warnings.add("本地安全兜底检测到提权或系统级操作。")
        var newData = CommandData()
        newData.command = data.command
        newData.explanation = data.explanation
        newData.interactive = data.interactive
        newData.safety.level = SafetyLevel.Privilege
        newData.safety.warnings = warnings
        return newData
    }

    data
}

func containsDanger(command: String): Bool {
    safetyContainsAny(command, [
        "rm -rf /",
        "rm -fr /",
        "rm -rf *",
        "rm -rf .",
        "mkfs",
        "dd if=",
        "dd of=",
        "chmod 777",
        "chmod -R 777",
        "chown -R",
        ":(){ :|:& };:",
        "> /dev/sd",
        "wipefs",
        "shred"
    ])
}

func containsPrivilege(command: String): Bool {
    safetyContainsAny(command, [
        "sudo ",
        " su ",
        "systemctl ",
        "service ",
        "apt-get ",
        "dnf ",
        "yum ",
        "pacman ",
        "zypper ",
        "apk add",
        "mount ",
        "umount "
    ])
}

func safetyContainsAny(command: String, patterns: Array<String>): Bool {
    for (p in patterns) {
        if (command.contains(p)) { return true }
    }
    false
}
