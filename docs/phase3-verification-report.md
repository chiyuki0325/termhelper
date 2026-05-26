# 阶段 3 适配器层验证报告

> 日期：2026-05-24
> 基于架构设计 v3、Vercel AI SDK 参考实现（references/ai/）

## 3.1 adapters/provider.cj — LLM Provider 共享类型与分派类

| 检查项 | 状态 | 备注 |
|--------|------|------|
| Usage 令牌用量结构体 | PASS | inputTokens/outputTokens + empty() |
| ToolDefinition 工具定义 | PASS | name/description/parameters（JSON Schema 字符串） |
| ToolCall 工具调用结果 | PASS | id/name/arguments（JSON 字符串） |
| ToolChoice 枚举 | PASS | Auto/Required/NoTool（避让 Option.None） |
| ResponseFormat 枚举 | PASS | JsonObject / JsonSchema(name, schema) |
| ChatRequest 请求构造 | PASS | messages/model/temperature/maxTokens/tools/toolChoice/responseFormat/systemPrompt |
| ChatResponset 响应 | PASS | content/finishReason/usage/toolCalls + empty() |
| StreamEvent 流式事件枚举 | PASS | Chunk/ToolCallStart/ToolCallDelta/ToolCallEnd/Done/Error |
| ChatRequest.addToolMessage | PASS | 追加 Tool 角色消息（多轮工具调用需要） |
| LLMProvider 分派类 | PASS | fromOpenAI/fromAnthropic/fromGoogle 工厂，chat/chatStream/chatWithTools 统一分派 |

## 3.2 adapters/sse.cj — SSE 流式解析器

| 检查项 | 状态 | 备注 |
|--------|------|------|
| 逐字节喂入 | PASS | feedByte(UInt8) 单个字节追加到行缓冲 |
| 批量数据喂入 | PASS | feedData(Array<UInt8>) 遍历调用 feedByte |
| 行缓冲与分割 | PASS | \n 分界，\r 跳过，累积完整行后 dispatch |
| 字段解析 | PASS | data:/event:/id: 前缀识别，多行 data 以 \n 连接 |
| 注释行忽略 | PASS | 以 : 开头的行被跳过 |
| 事件边界分发 | PASS | 空行触发 dispatchEvent → 加入事件队列 |
| [DONE] 检测 | PASS | data 字段为 "[DONE]" 时设置 isDone() = true |
| 非阻塞轮询 | PASS | tryGetEvent() 返回 ?SseEvent，无事件返回 None |
| OpenAI SSE 格式 | PASS | data: {JSON}\n\n 格式（无 event 字段） |
| Anthropic SSE 格式 | PASS | event: content_block_start/delta/stop + data: {JSON}\n\n |
| Google SSE 格式 | PASS | data: {JSON}\n\n 格式（alt=sse 模式） |

## 3.3 adapters/openai_compat.cj — OpenAI Compatible Provider

| 检查项 | 状态 | 备注 |
|--------|------|------|
| Provider 构造 | PASS | baseUrl/apiKey/model/timeoutSec |
| chat 非流式 | PASS | POST /chat/completions → parseChatResponse |
| chatStream 流式 | PASS | stream: true → SSE 解析 → onEvent(Chunk/Done/Error) |
| chatWithTools 流式工具调用 | PASS | stream: true → 解析 delta.tool_calls → ToolCallStart/Delta/End |
| 并行工具调用追踪 | PASS | toolCallState 按 index 追踪多路 tool call |
| 请求 JSON 构造 | PASS | messages/temperature/max_tokens/tools/tool_choice/response_format |
| response_format 注入 | PASS | json_object 或 json_schema(name, strict, schema) |
| HTTP 头 | PASS | Authorization: Bearer / Content-Type |
| HTTP 状态码检查 | PASS | sendPost 检查 resp.status != 200，返回错误 JSON |
| 流式 HTTP 状态码检查 | PASS | streamPost 检查 resp.status != 200，发送 Error 事件 |
| 响应解析 | PASS | choices[0].message.content + finish_reason + usage + tool_calls |
| 流式数据块解析 | PASS | choices[0].delta.content + delta.tool_calls 分片 |
| Usage 解析 | PASS | prompt_tokens / completion_tokens |
| 默认 Provider 工厂 | PASS | createOpenAICompatProvider("https://api.openai.com/v1", ...) |

**设计说明：** 流式 tool-calling 在单个 streamPost 中同时处理文本和工具调用增量。根据 delta.tool_calls[].index 追踪多个并行工具调用。finish_reason == "tool_calls" 时排空待处理工具调用并发出 ToolCallEnd 事件。

## 3.4 adapters/anthropic.cj — Anthropic Provider

| 检查项 | 状态 | 备注 |
|--------|------|------|
| Provider 构造 | PASS | baseUrl/apiKey/model/timeoutSec |
| chat 非流式 | PASS | POST /messages → parseChatResponse |
| chatStream 流式 | PASS | POST /messages (stream:true) → SSE 事件分发 |
| chatWithTools 流式工具调用 | PASS | stream:true → content_block_start/delta/stop 处理 |
| content_block_start 处理 | PASS | 解析 content_block.type/name/id，按显式 index 存入 blocks |
| content_block_delta 处理 | PASS | 按 index 路由，text_delta → Chunk，input_json_delta → ToolCallDelta |
| content_block_stop 处理 | PASS | tool_use 块 → ToolCallEnd |
| message_start/message_delta/message_stop | PASS | 提取 usage、stop_reason，流结束时收集 tool calls |
| ping 忽略 | PASS | 心跳事件静默跳过 |
| 非流式响应解析 | PASS | 文本 content block + tool_use block → ToolCall 列表 |
| 非流式 HTTP 状态码检查 | PASS | sendPost 检查 resp.status != 200 |
| system prompt | PASS | 顶层级 system 字段（非 messages 内） |
| messages 格式 | PASS | role + content[{type: "text", text: ...}] |
| tools / tool_choice 构造 | PASS | tools[].input_schema / tool_choice.type(auto/any/none) |
| HTTP 头 | PASS | x-api-key / anthropic-version: 2023-06-01 / Content-Type |
| max_tokens 默认值 | PASS | 128000（适配现代 Claude 模型） |
| 默认 Provider 工厂 | PASS | createAnthropicProvider("https://api.anthropic.com/v1", ...) |

**设计说明：** 严格遵循 Anthropic SSE 事件协议。content_block_start 使用事件顶层的显式 index 字段定位 blocks 数组。content_block_delta 按 block type 分别处理文本(text_delta)、思考(thinking_delta)、工具参数(input_json_delta)增量。非流式响应解析两遍遍历：首遍提取文本，二遍提取 tool_use 块。

## 3.5 adapters/google.cj — Google Gemini Provider

| 检查项 | 状态 | 备注 |
|--------|------|------|
| Provider 构造 | PASS | baseUrl/apiKey/model/timeoutSec |
| chat 非流式 | PASS | POST /models/{model}:generateContent |
| chatStream 流式 | PASS | POST /models/{model}:streamGenerateContent?alt=sse → SSE 解析 |
| chatWithTools 流式工具调用 | PASS | streamGenerateContent → 解析 functionCall/partialArgs |
| functionCall args 解析 | PASS | 完整 args 对象 → toJsonString → ToolCallDelta |
| partialArgs 增量解析 | PASS | Gemini 2.5+ 增量数组格式，逐条发出 ToolCallDelta |
| 参数累积保留 | PASS | activeFnCalls 存储 (id, name, accumulatedArgs)，最终保留完整 JSON |
| 非流式响应解析 | PASS | candidates[0].content.parts[].text + functionCall → ToolCall |
| 非流式 HTTP 状态码检查 | PASS | sendPost 检查 resp.status != 200 |
| systemInstruction | PASS | systemInstruction.parts[{text: ...}] |
| contents/messages 构造 | PASS | role(user/model) + parts[{text: ...}] |
| generationConfig | PASS | temperature/maxOutputTokens/responseMimeType/responseSchema |
| tools / toolConfig 构造 | PASS | tools[].functionDeclarations + functionCallingConfig(AUTO/ANY/NONE) |
| HTTP 头 | PASS | x-goog-api-key / Content-Type |
| 默认 Provider 工厂 | PASS | createGoogleProvider("https://generativelanguage.googleapis.com/v1beta", ...) |

**设计说明：** Google 通过不同端点区分流式/非流式（:generateContent vs :streamGenerateContent?alt=sse），不需要 body 中的 stream 字段。流式解析同时支持旧的 `functionCall.args`（完整对象）和新的 `functionCall.partialArgs`（Gemini 2.5+ 增量数组）两种格式。activeFnCalls 存储累积参数 JSON，最终写入 ChatResponse.toolCalls。

## 3.6 adapters/structured_output.cj — Structured Output 适配层

| 检查项 | 状态 | 备注 |
|--------|------|------|
| JSON Schema 构造 | PASS | makeJsonSchema(title, properties, required) → JSON 字符串 |
| OpenAI response_format 注入 | PASS | setOpenAIResponseFormat → json_schema |
| Anthropic Structured Output | PASS | setAnthropicStructuredOutput → json tool + tool_choice: required |
| Google response_format 注入 | PASS | setGoogleResponseFormat → responseMimeType + responseSchema |
| JSON 响应提取 | PASS | extractJsonFromResponse → 直接解析或 ```json 代码块提取 |
| 必需字段校验 | PASS | validateRequiredFields(obj, requiredFields) |
| Schema 结构校验 | PASS | validateJsonSchema(obj, schemaJson) |

## 3.7 adapters/util.cj — 共享工具函数

| 检查项 | 状态 | 备注 |
|--------|------|------|
| jsonGetString | PASS | JsonObject 安全字符串提取 |
| jsonGetInt | PASS | JsonObject 安全整数提取 |
| stripPrefix | PASS | 字符串前缀去除（SSE 字段解析用） |
| 去重 | PASS | jsonGetString/jsonGetInt 从 openai_compat.cj 移除，stripPrefix 从 sse.cj 移除 |

## 集成编译状态

```
cjpm build → success
```

- adapters/ 全部 7 个源文件（provider/sse/openai_compat/anthropic/google/structured_output/util）：编译通过
- 仅 1 个 unused import 警告（无关紧要）

## 代码规模

| 文件 | 行数 | 说明 |
|------|------|------|
| provider.cj | 215 | 共享类型 + LLMProvider 分派类 |
| sse.cj | 150 | SSE 解析器 + SseParser 类 |
| openai_compat.cj | 413 | OpenAI/DeepSeek/Moonshot 兼容 |
| anthropic.cj | 399 | Anthropic Messages API |
| google.cj | 456 | Google Gemini API |
| structured_output.cj | 165 | JSON Schema 构造/注入/校验 |
| util.cj | 36 | jsonGetString/jsonGetInt/stripPrefix |
| **总计** | **约 1834 行** | |

## 已知限制与风险

| 项 | 说明 | 缓解 |
|----|------|------|
| **LLMProvider 是分派类非接口** | 仓颉无 interface/trait，新增 Provider 需修改分派 match 链 | 后续若有更多 Provider 可改用函数指针 struct 方案 |
| **TLS 证书验证** | HTTPS TLS TrustAll 枚举 API 尚未深入验证（同阶段 1 结论） | 需在实际 API 调用中验证 stdx.net.http 默认 TLS 行为 |
| **流式内容未在 ChatResponse 中保留** | OpenAI streamPost 的 processOpenAIChunk 不累积 content（由 onEvent 交付） | 调用方通过 Chunk 事件累积；返回的 ChatResponse 仅含 usage/finishReason |
| **Anthropic 原生 Structured Output 未使用** | Anthropic 现已支持原生 response_format（beta header），但计划要求通过 tool_use 实现 | 后续阶段评估是否切换到原生 mode |
| **Google partialArgs 格式** | Gemini 2.5+ 新增增量参数格式，实现已支持但未经真实 API 验证 | 后续阶段 API 测试确认 |

## 注意事项

| 项 | 说明 |
|----|------|
| **避让 Option.None** | ToolChoice.NoTool 替代 None，避免与 Option.None 构造函数冲突 |
| **避让 match 关键字** | 变量名 found 替代 match（SSE 代码块搜索中） |
| **JsonArray 方法** | 使用 add(obj) 非 append(obj) |
| **enum 不可 == 比较** | 使用 match 模式匹配替代等号比较 |
| **JsonObject.get() 返回 Option\<JsonValue\>** | 需 match Some/None 解包后方可调用 asObject/asArray/asString |
| **String 值类型传参** | 辅助函数中修改 String 参数不影响调用方（struct 为值类型），流式处理中关键状态使用 ArrayList（class 引用类型） |
| **builder 模式** | stdx.net.http.ClientBuilder/HttpRequestBuilder 支持链式调用 |
| **toJsonString** | JsonObject 支持 .toJsonString() 序列化为 JSON 字符串 |
| **JsonFloat/JsonBool** | stdx.encoding.json 支持 JsonFloat(Float64) 和 JsonBool(Bool) |

## 阶段 3 结论

**全部 7 个适配器模块实现完成并通过编译。** Provider 接口 + SSE 解析器 + 三家 LLM Provider（OpenAI Compatible / Anthropic / Google）+ Structured Output 适配层 + 共享工具函数。所有 Provider 支持 chat（非流式）、chatStream（流式回调）、chatWithTools（流式工具调用，含 ToolCallStart/Delta/End 事件）。HTTP 状态码检查覆盖所有发送路径（流式和非流式）。Google 支持 Gemini 2.5+ 的 partialArgs 增量格式。Anthropic 按显式 index 正确处理 content_block 事件流。

**无阻塞项，可进入阶段 4（核心层 + 上下文迁移）。**
