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
        req.systemPrompt = Some(buildMainSystemPrompt(ctx))
        req.maxTokens = Some(4096)

        if (history.size == 0 && query.size > 0) {
            req.addUserMessage(query)
        } else {
            for (i in 0..history.size) { req.messages.add(history[i]) }
        }

        let schema = llmResponseSchema()
        if (config.provider == "anthropic") {
            setAnthropicStructuredOutput(req, "termhelper_response", schema)
        } else if (config.provider == "google") {
            setGoogleResponseFormat(req, "termhelper_response", schema)
        } else {
            setOpenAIResponseFormat(req, "termhelper_response", schema)
        }
        req
    }
}
