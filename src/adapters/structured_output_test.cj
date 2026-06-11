package termhelper.adapters

import std.collection.*

@Test
func extractJsonFromResponseParsesPlainJsonObject(): Unit {
    let obj = extractJsonFromResponse(ChatResponse("{\"command\":\"pwd\",\"interactive\":false}", "stop", Usage.empty()))

    @Expect(obj.get("command").getOrThrow().asString().getValue(), "pwd")
    @Expect(obj.get("interactive").getOrThrow().asBool().getValue(), false)
}

@Test
func extractJsonFromResponseParsesJsonFenceWithSurroundingNoise(): Unit {
    let obj = extractJsonFromResponse(
        ChatResponse(
            """
            text before
            ```json
            {"type":"command","command":"ls -la"}
            ```
            text after
            """,
            "stop", Usage.empty()))

    @Expect(obj.get("type").getOrThrow().asString().getValue(), "command")
    @Expect(obj.get("command").getOrThrow().asString().getValue(), "ls -la")
}

@Test
func extractJsonFromResponseReturnsEmptyObjectForInvalidJson(): Unit {
    let obj = extractJsonFromResponse(ChatResponse("not json", "stop", Usage.empty()))

    @Expect(obj.containsKey("command"), false)
}

@Test
func validateRequiredFieldsRequiresAllNamedFields(): Unit {
    let obj = extractJsonFromResponse(ChatResponse("{\"command\":\"pwd\",\"safety\":{}}", "stop", Usage.empty()))
    let required = ArrayList<String>()
    required.add("command")
    required.add("safety")

    @Expect(validateRequiredFields(obj, required), true)

    required.add("explanation")
    @Expect(validateRequiredFields(obj, required), false)
}

@Test
func validateJsonSchemaChecksRequiredFieldsAndRejectsInvalidSchema(): Unit {
    let obj = extractJsonFromResponse(ChatResponse("{\"command\":\"pwd\",\"safety\":{}}", "stop", Usage.empty()))
    let required = ArrayList<String>()
    required.add("command")
    required.add("safety")
    let properties = ArrayList<(String, String, String)>()
    properties.add(("command", "string", "shell command"))
    properties.add(("safety", "object", "safety info"))

    @Expect(validateJsonSchema(obj, makeJsonSchema("LLMResponse", properties, required)), true)

    required.add("explanation")
    @Expect(validateJsonSchema(obj, makeJsonSchema("LLMResponse", properties, required)), false)
    @Expect(validateJsonSchema(obj, "{bad schema"), false)
}
