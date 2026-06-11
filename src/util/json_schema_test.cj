package termhelper.util

import termhelper.types.*
import stdx.encoding.json.*

@Test
func llmResponseSchemaClosesAllObjectSchemasForOpenAIStrictMode(): Unit {
    let root = JsonValue.fromStr(llmResponseSchema()).asObject()
    @Expect(requiredContains(root, "type"), true)
    @Expect(requiredContains(root, "data"), true)
    @Expect(allObjectSchemasRejectAdditionalProperties(root), true)

    let properties = root.get("properties").getOrThrow().asObject()
    let dataSchema = properties.get("data").getOrThrow().asObject()
    let variants = dataSchema.get("anyOf").getOrThrow().asArray()
    @Expect(variants.size(), 3)
}

@Test
func llmResponseSchemaForGoogleOmitsAdditionalProperties(): Unit {
    let root = JsonValue.fromStr(llmResponseSchemaForProvider("google")).asObject()
    @Expect(noObjectContainsAdditionalProperties(root), true)
}

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

func requiredContains(schema: JsonObject, name: String): Bool {
    let required = schema.get("required").getOrThrow().asArray()
    for (i in 0..required.size()) {
        match (required.get(i)) {
            case Some(value) =>
                if (isJsonString(value, name)) {
                    return true
                }
            case None => ()
        }
    }
    false
}

func allObjectSchemasRejectAdditionalProperties(value: JsonValue): Bool {
    match (value.kind()) {
        case JsObject =>
            let obj = value.asObject()
            if (isObjectSchema(obj) && !hasFalseAdditionalProperties(obj)) {
                return false
            }
            for ((_, child) in obj.getFields()) {
                if (!allObjectSchemasRejectAdditionalProperties(child)) {
                    return false
                }
            }
            true
        case JsArray =>
            let arr = value.asArray()
            for (i in 0..arr.size()) {
                match (arr.get(i)) {
                    case Some(child) =>
                        if (!allObjectSchemasRejectAdditionalProperties(child)) {
                            return false
                        }
                    case None => ()
                }
            }
            true
        case _ => true
    }
}

func isObjectSchema(obj: JsonObject): Bool {
    match (obj.get("type")) {
        case Some(value) => isJsonString(value, "object")
        case None => false
    }
}

func hasFalseAdditionalProperties(obj: JsonObject): Bool {
    match (obj.get("additionalProperties")) {
        case Some(value) => match (value.kind()) {
            case JsBool => !value.asBool().getValue()
            case _ => false
        }
        case None => false
    }
}

func isJsonString(value: JsonValue, expected: String): Bool {
    match (value.kind()) {
        case JsString => value.asString().getValue() == expected
        case _ => false
    }
}

func noObjectContainsAdditionalProperties(value: JsonValue): Bool {
    match (value.kind()) {
        case JsObject =>
            let obj = value.asObject()
            if (obj.containsKey("additionalProperties")) {
                return false
            }
            for ((_, child) in obj.getFields()) {
                if (!noObjectContainsAdditionalProperties(child)) {
                    return false
                }
            }
            true
        case JsArray =>
            let arr = value.asArray()
            for (i in 0..arr.size()) {
                match (arr.get(i)) {
                    case Some(child) =>
                        if (!noObjectContainsAdditionalProperties(child)) {
                            return false
                        }
                    case None => ()
                }
            }
            true
        case _ => true
    }
}
