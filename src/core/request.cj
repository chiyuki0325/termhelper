package termhelper.core

import termhelper.types.*
import termhelper.infra.*
import termhelper.adapters.*
import termhelper.util.*
import std.collection.*

public class RequestBuilder {
    public init() {}

    public func build(query: String, history: ArrayList<Message>, ctx: EnvironmentContext, config: Config): ChatRequest {
        let req = ChatRequest(config.llm.model)
        req.maxTokens = Some(4096)
        req.structuredOutputMode = config.llm.structuredOutputMode

        let useJsonObject = config.llm.structuredOutputMode == "json_object"

        if (useJsonObject) {
            req.systemPrompts.add(buildObjectModeStaticPrompt())
            req.systemPrompts.add(buildEnvironmentContextPrompt(ctx))
            req.systemPrompt = Some(buildObjectModePrompt(ctx))
        } else {
            // auto / json_schema: 主 prompt 精简，fallback prompt 详细
            req.systemPrompts.add(buildSchemaModeStaticPrompt())
            req.systemPrompts.add(buildEnvironmentContextPrompt(ctx))
            req.systemPrompt = Some(buildSchemaModePrompt(ctx))
            req.fallbackSystemPrompts.add(buildObjectModeStaticPrompt())
            req.fallbackSystemPrompts.add(buildEnvironmentContextPrompt(ctx))
            req.fallbackSystemPrompt = Some(buildObjectModePrompt(ctx))
        }

        if (history.size == 0 && query.size > 0) {
            req.addUserMessage(query)
        } else {
            for (i in 0..history.size) { req.messages.add(history[i]) }
        }

        let schema = llmResponseSchemaForProvider(config.provider)
        if (config.provider == "anthropic") {
            setAnthropicStructuredOutput(req, "termhelper_response", schema)
        } else if (config.provider == "google") {
            setGoogleResponseFormat(req, "termhelper_response", schema)
        } else if (useJsonObject) {
            setOpenAIJsonObjectResponseFormat(req)
        } else {
            setOpenAIResponseFormat(req, "termhelper_response", schema)
        }
        req
    }
}
