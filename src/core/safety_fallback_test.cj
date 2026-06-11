package termhelper.core

import termhelper.types.*

@Test
func safetyFallbackPromotesDangerousCommand(): Unit {
    let response = applySafetyFallback(LLMResponse.Command(commandData("rm -rf /", SafetyLevel.Safe)))

    match (response) {
        case LLMResponse.Command(data) =>
            @Expect(safetyLevelName(data.safety.level), "danger")
            @Expect(data.safety.warnings.size, 1)
        case _ => @Fail("expected command response")
    }
}

@Test
func safetyFallbackPromotesPrivilegeCommand(): Unit {
    let response = applySafetyFallback(LLMResponse.Command(commandData("sudo systemctl restart sshd", SafetyLevel.Safe)))

    match (response) {
        case LLMResponse.Command(data) =>
            @Expect(safetyLevelName(data.safety.level), "privilege")
            @Expect(data.safety.warnings.size, 1)
        case _ => @Fail("expected command response")
    }
}

@Test
func safetyFallbackLeavesAlreadyClassifiedDangerUntouched(): Unit {
    let data = commandData("rm -rf /", SafetyLevel.Danger)
    data.safety.warnings.add("existing")

    let response = applySafetyFallback(LLMResponse.Command(data))

    match (response) {
        case LLMResponse.Command(newData) =>
            @Expect(safetyLevelName(newData.safety.level), "danger")
            @Expect(newData.safety.warnings.size, 1)
            @Expect(newData.safety.warnings[0], "existing")
        case _ => @Fail("expected command response")
    }
}

@Test
func safetyFallbackLeavesOrdinaryCommandSafe(): Unit {
    let response = applySafetyFallback(LLMResponse.Command(commandData("ls -la", SafetyLevel.Safe)))

    match (response) {
        case LLMResponse.Command(data) =>
            @Expect(safetyLevelName(data.safety.level), "safe")
            @Expect(data.safety.warnings.size, 0)
        case _ => @Fail("expected command response")
    }
}

func commandData(command: String, level: SafetyLevel): CommandData {
    let data = CommandData()
    data.command = command
    data.safety.level = level
    data
}

func safetyLevelName(level: SafetyLevel): String {
    match (level) {
        case SafetyLevel.Safe => "safe"
        case SafetyLevel.Caution => "caution"
        case SafetyLevel.Danger => "danger"
        case SafetyLevel.Privilege => "privilege"
    }
}
