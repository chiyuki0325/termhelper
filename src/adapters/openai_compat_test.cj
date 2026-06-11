package termhelper.adapters

import stdx.encoding.json.*

@Test
func parseOpenAIChatCompletionResponseReadsMessageContent(): Unit {
    let message = JsonObject()
    message.put("role", JsonString("assistant"))
    message.put("content", JsonString("{\"type\":\"clarify\",\"data\":{\"question\":\"Which file?\"}}"))
    let response = parseOpenAIChatCompletionResponse(chatCompletionBody(message, "stop", includeUsage: true))

    @Expect(response.finishReason, "stop")
    @Expect(response.content.contains("\"type\":\"clarify\""), true)
    @Expect(response.usage.inputTokens, 11)
    @Expect(response.usage.outputTokens, 7)
}

@Test
func parseOpenAIChatCompletionResponseFallsBackToParsedObject(): Unit {
    let parsedData = JsonObject()
    parsedData.put("question", JsonString("Which file?"))
    let parsed = JsonObject()
    parsed.put("type", JsonString("clarify"))
    parsed.put("data", parsedData)
    let message = JsonObject()
    message.put("role", JsonString("assistant"))
    message.put("content", JsonNull())
    message.put("parsed", parsed)
    let response = parseOpenAIChatCompletionResponse(chatCompletionBody(message, "stop", includeUsage: false))

    @Expect(response.content.contains("clarify"), true)
    @Expect(response.content.contains("Which file?"), true)
}

@Test
func parseOpenAIChatCompletionResponseReadsNonStreamToolCalls(): Unit {
    let funcObj = JsonObject()
    funcObj.put("name", JsonString("termhelper_response"))
    funcObj.put("arguments", JsonString("{\"type\":\"clarify\",\"data\":{\"question\":\"Which file?\"}}"))
    let toolCall = JsonObject()
    toolCall.put("id", JsonString("call_1"))
    toolCall.put("type", JsonString("function"))
    toolCall.put("function", funcObj)
    let toolCalls = JsonArray()
    toolCalls.add(toolCall)
    let message = JsonObject()
    message.put("role", JsonString("assistant"))
    message.put("content", JsonString(""))
    message.put("tool_calls", toolCalls)
    let response = parseOpenAIChatCompletionResponse(chatCompletionBody(message, "tool_calls", includeUsage: false))

    @Expect(response.finishReason, "tool_calls")
    @Expect(response.toolCalls.size, 1)
    @Expect(response.toolCalls[0].id, "call_1")
    @Expect(response.toolCalls[0].name, "termhelper_response")
    @Expect(response.toolCalls[0].arguments.contains("\"type\":\"clarify\""), true)
}

func chatCompletionBody(message: JsonObject, finishReason: String, includeUsage!: Bool): String {
    let choice = JsonObject()
    choice.put("message", message)
    choice.put("finish_reason", JsonString(finishReason))
    let choices = JsonArray()
    choices.add(choice)
    let root = JsonObject()
    root.put("choices", choices)
    if (includeUsage) {
        let usage = JsonObject()
        usage.put("prompt_tokens", JsonInt(11))
        usage.put("completion_tokens", JsonInt(7))
        root.put("usage", usage)
    }
    root.toJsonString()
}
