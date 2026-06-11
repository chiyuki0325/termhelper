package termhelper.util

import termhelper.types.*

@Test
func parseCommandWireFormatNormalizesLowercaseSafety(): Unit {
    let response = parseLLMResponseJson(
        """
        {
          "type": "command",
          "data": {
            "command": "ls -la",
            "explanation": {"summary": "List files", "breakdown": []},
            "interactive": false,
            "safety": {"level": "safe", "warnings": []}
          }
        }
        """)

    match (response) {
        case Some(LLMResponse.Command(data)) =>
            @Expect(data.command, "ls -la")
            @Expect(safetyLevelToString(data.safety.level), "safe")
            @Expect(data.factEdits.size, 0)
        case _ => @Fail("expected command response")
    }
}

@Test
func parseCommandFlatJsonObjectFallback(): Unit {
    let response = parseLLMResponseJson(
        """
        {
          "type": "command",
          "command": "pwd",
          "explanation": {"summary": "Print directory", "breakdown": []},
          "interactive": false,
          "safety": {"level": "caution", "warnings": ["check path"]}
        }
        """)

    match (response) {
        case Some(LLMResponse.Command(data)) =>
            @Expect(data.command, "pwd")
            @Expect(safetyLevelToString(data.safety.level), "caution")
            @Expect(data.safety.warnings[0], "check path")
        case _ => @Fail("expected command response")
    }
}

@Test
func parseInvestigateFillsMissingContextUpdates(): Unit {
    let response = parseLLMResponseJson(
        """
        {
          "type": "investigate",
          "data": {
            "reason": "Need package manager",
            "commands": [{"command": "command -v apt", "rationale": "Probe apt"}]
          }
        }
        """)

    match (response) {
        case Some(LLMResponse.Investigate(data)) =>
            @Expect(data.reason, "Need package manager")
            @Expect(data.commands.size, 1)
            @Expect(data.contextUpdates.size, 0)
        case _ => @Fail("expected investigate response")
    }
}

@Test
func parseRejectsInvalidResponseShape(): Unit {
    @Expect(parseLLMResponseJson("{\"type\":\"command\",\"data\":[]}").isNone())
    @Expect(parseLLMResponseJson("{\"type\":\"unknown\",\"data\":{}}").isNone())
    @Expect(parseLLMResponseJson("not-json").isNone())
}
