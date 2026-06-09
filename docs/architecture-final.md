# 智能终端助手 架构设计 v3

> 基于 [需求分析说明书 v5](./requirements-final.md) 和 [技术选型](./tech-selection.md)
> v1 审议结论：事件总线过度设计、LLM/执行器分层不当、PTY 应属基础设施、PTY 执行应改为 agentic tool-calling 循环
> v2 审议结论：PTY LLM 调用风暴、Provider 接口缺 tool-calling、Session 线程安全、TUI/PTY 渲染冲突等 20 项缺陷（详见 v3 审议报告）

## 1. 架构总览

### 1.1 分层架构

```
┌──────────────────────────────────────────────────────────────┐
│                      入口 (main.cj)                           │
│  命令行解析 → 子命令/查询分发 → 配置加载 → 上下文加载 → 启动   │
│  env     query                                              │
│  --install  --uninstall                                     │
└──────────────────────────┬───────────────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────────────┐
│                      TUI 层 (tui/)                            │
│  ┌──────────┐  ┌─────────────┐  ┌──────────────────────────┐ │
│  │  Screen  │  │  Components  │  │  Theme / Input / Signal  │ │
│  │  Router  │  │  (可复用组件) │  │  (颜色/键盘/信号处理)     │ │
│  └──────────┘  └─────────────┘  └──────────────────────────┘ │
│                                                                 │
│  Screen: Loading → Result → Execute/PtyAgentic/Prompt/Error    │
│  Prompt: Investigate / Clarify / Modify                        │
│  主循环: poll_event → 分发键盘 → 检查后台通道 → draw           │
│                                                                 │
│  PtyAgentic 渲染策略: PTY虚拟终端全屏渲染为底层 +               │
│                       ratatui overlay面板浮动在上层             │
└──────────────────────────┬───────────────────────────────────┘
                           │ Channel<AppEvent> (后台→TUI)
                           │ 直接调用 (TUI→Core, 仅主线程)
┌──────────────────────────▼───────────────────────────────────┐
│                      核心层 (core/)                            │
│  ┌────────────┐  ┌────────────┐  ┌─────────────────────────┐ │
│  │  Session   │  │  Context   │  │  PtyAgentLoop           │ │
│  │  (会话编排) │  │  Manager   │  │  (PTY agentic 循环,     │ │
│  │  [主线程]   │  │  +Migration│  │   含调度/compact/上限)    │ │
│  └─────┬──────┘  └─────┬──────┘  └────────────┬────────────┘ │
│        │               │                      │               │
│  ┌─────┴───────────────┴──────────────────────┴────────────┐ │
│  │  RequestBuilder  │  SafetyFallback  │  LLMResponseParser │ │
│  └──────────────────┴──────────────────┴────────────────────┘ │
└──────────────────────────┬───────────────────────────────────┘
                           │
            ┌──────────────┴──────────────┐
            │                             │
┌───────────▼──────────┐    ┌────────────▼──────────────────────┐
│  适配器层 (adapters/) │    │  基础设施层 (infra/)               │
│                      │    │                                   │
│  LLM Provider 接口    │    │  ┌──────────┐ ┌───────────────┐  │
│  ├─ chat             │    │  │  Pty     │ │  Spawn        │  │
│  ├─ chatStream       │    │  │  (创建/  │ │  (子进程执行)   │  │
│  ├─ chatWithTools    │    │  │   读写/  │ └───────────────┘  │
│  ├─ OpenAICompat    │    │  │   销毁)  │ ┌───────────────┐  │
│  ├─ Anthropic       │    │  └──────────┘ │  Clipboard    │  │
│  └─ Google          │    │                │ (OSC52→       │  │
│  ├─ SseParser       │    │                │  Wayland→     │  │
│  └─ StructuredOutput│    │                │  X11→降级)    │  │
│                      │    │                └───────────────┘  │
│                      │    │  ┌──────────┐ ┌───────────────┐  │
│                      │    │  │  Config  │ │  ShellRC      │  │
│                      │    │  │  Manager │ │  Manager      │  │
│                      │    │  └──────────┘ └───────────────┘  │
│                      │    │  ┌──────────────────────────────┐ │
│                      │    │  │  FileStore (JSON r/w + flock)│ │
│                      │    │  │  + Migration                 │ │
│                      │    │  └──────────────────────────────┘ │
└──────────────────────┘    └──────────────────────────────────┘
```

**与 v2 的关键差异：**

| v2 | v3 | 理由 |
|----|----|------|
| `chat` / `chatStream` 两种方法 | 增加 `chatWithTools` 方法，支持 tool-calling | PTY agentic 循环需要 LLM 选择工具 |
| JSON 文本提取容错 | Provider 原生 Structured Output（`response_format` / tool use / `response_schema`） | 从源头保证 JSON 合规，消除解析脆弱性 |
| PTY agentic 循环无成本控制 | 事件驱动调度 + compact buffer + 终端文本归一化 + 单次会话最大 50 轮 + 用量追踪 | 避免 LLM 调用风暴、长输出重复计费和进度条刷屏污染上下文 |
| `PtyTool::Wait` 无参数 | `Wait(duration_ms)` — LLM 指定等待时长 | 避免空转轮询 |
| Session 被主线程和后台任务并发访问 | Session 仅主线程持有；后台任务通过 Channel 传回数据，主线程追加 | 消除数据竞争，无需加锁 |
| PTY 输出在 ratatui 组件中渲染 | PtyAgentic 屏：虚拟终端 = 真实终端大小 → PTY 内容全屏渲染为底层 → ratatui overlay 面板浮动在上 | 避免 ANSI 序列与 ratatui 绘制冲突；用户看到与原生终端一致的输出 |
| `--install` / `--uninstall` 为自然语言参数 | 硬编码保留词 `--install` / `--uninstall`，前缀 `--` 精确匹配 | 消除 "?? install something" 歧义 |
| 无信号处理 | SIGINT/SIGTERM/SIGHUP 处理器 + panic hook → 恢复终端 + 清理 PTY 子进程 | 防止异常退出后终端不可用 |
| 无 LLM 超时 | `llm_timeout_sec` 配置 + connect/read/idle 三级超时 | 避免挂起 HTTP 连接导致无限 spinner |
| 剪贴板仅 Wayland/X11 | OSC 52 → Wayland → X11 → 降级展示 | SSH 远程会话剪贴板可用 |
| `context.json` 无版本号 | `version` 字段 + `ContextMigration` 模块 | 结构演变时前向兼容 |
| `CommandResult` 用于 PTY（stdout/stderr 分离） | `PtyResult` 独立类型：合并输出流 + LLM 摘要 | PTY 的 master fd 不分离 stdout/stderr |
| `PromptMode` 仅 Investigate / Clarify | 增加 `Modify` 变体 | "修改"流程 UI 入口明确 |
| 无终端 resize 处理 | SIGWINCH → 更新 ratatui + PTY ioctl TIOCSWINSZ | 终端大小变化时正确渲染 |
| 无流式内容展示 | Loading 屏实时渲染 LLM 流式片段 | 用户感知 LLM 正在生成，非空白等待 |
| `ask_user` 无敏感标记 | `ask_user(question, sensitive)` — 密码类问题时 `sensitive: true` | 密码遮罩输入 + 不回传 LLM 上下文 |
| `flock` 读写分离锁 | 读-修改-写周期全程 `LOCK_EX` 排他锁 | 防止多实例丢失更新 |
| 无重试策略细节 | 3 次上限 + 指数退避 + 可重试/不可重试错误分类 | 快速失败 vs 合理等待的平衡 |
| RC 文件简单字符串匹配删除 | 安装时用注释标记包围 `# >>> termhelper >>>` / `# <<< termhelper <<<` | 卸载时安全定位，不受用户手动修改影响 |
| `context.json` 无迁移机制 | `ContextMigration` 模块：version 检查 → 逐版本迁移 | 结构演变不丢数据 |
| `AppEvent` 无 Modify 语义 | `ModifySubmitted(String)` 事件 → 追加到 Session → 发起 LLM | 修改流程的事件驱动路径明确 |

### 1.2 设计原则

| 原则 | 说明 |
|------|------|
| **TUI 主线程不阻塞** | LLM 调用、命令执行在后台任务运行，通过 Channel 通知 TUI |
| **Session 仅主线程持有** | 后台任务只通过 Channel 传回数据，主线程在 tryRecv 时更新 Session，消除并发竞争 |
| **Screen 状态机驱动 UI** | 6 个 Screen（含 Prompt 的三个子模式），键盘事件直接分发，不经过中间事件层 |
| **适配器隔离外部服务** | LLM Provider 实现在 adapter/ 下，通过接口与 core 解耦 |
| **基础设施封装 OS 原语** | PTY 创建、子进程 spawn、剪贴板调用均在 infra/ 下，不含业务逻辑 |
| **Agentic PTY 循环** | 交互式命令执行采用 LLM tool-calling 循环，每轮选择工具执行；含事件调度、compact buffer 和调用上限 |
| **安全默认** | PTY 默认逐次确认，诊断命令默认需授权，危险命令二次确认，敏感输入不回传 LLM |
| **会话隔离** | 对话历史仅内存保留，进程退出即丢弃；仅环境上下文持久化 |
| **坚持运行** | TUI 始终给用户可操作的回退路径，不因任何错误崩溃退出；崩溃时恢复终端状态 |
| **结构化输出** | LLM 响应使用 Provider 原生 Structured Output 机制（`response_format` / tool use），保证 JSON Schema 合规 |

---

## 2. 包结构

```
termhelper/
├── cjpm.toml
├── src/
│   ├── main.cj                          # 入口：参数解析、子命令分发、配置加载、启动 TUI
│   │
│   ├── types/
│   │   ├── llm.cj                       # LLMResponse, CommandData, InvestigateData, SafetyLevel 等
│   │   ├── session.cj                   # Message, MessageRole, EnvironmentContext
│   │   └── pty.cj                       # PtyTool, PtyLoopState, PtyResult
│   │
│   ├── tui/
│   │   ├── tui.cj                       # TUI 初始化、主循环、Screen 路由、Channel 接收
│   │   ├── theme.cj                     # 颜色常量 (危险=橙色、成功=绿色等)
│   │   ├── input.cj                     # 键盘事件 → 应用动作转换
│   │   ├── signal.cj                    # 信号处理器 (SIGINT/SIGTERM/SIGHUP/SIGWINCH)
│   │   ├── screens/
│   │   │   ├── loading.cj               # 加载态：spinner + 流式 LLM 文本实时展示
│   │   │   ├── result.cj                # 结果态：命令 + 分解说明 + 安全警告 + 选项菜单
│   │   │   ├── execute.cj               # 普通执行态：spawn 输出滚动展示
│   │   │   ├── pty_agentic.cj           # PTY agentic 态：全屏 PTY 渲染 + overlay 控制面板
│   │   │   ├── prompt.cj                # 交互提示态：investigate / clarify / modify
│   │   │   └── error.cj                 # 错误态：错误信息 + 重试/退出
│   │   └── components/
│   │       ├── command_display.cj        # 命令展示 (含语法高亮占位)
│   │       ├── explanation.cj            # 命令分解说明
│   │       ├── safety_badge.cj           # 安全等级徽章
│   │       ├── option_menu.cj            # 选项菜单 (键盘导航)
│   │       ├── spinner.cj                # 加载动画
│   │       ├── text_input.cj             # 文本输入组件 (含密码遮罩模式)
│   │       └── overlay_panel.cj          # PTY overlay 浮动面板 (状态栏/确认弹窗)
│   │
│   ├── core/
│   │   ├── session.cj                   # Session：对话历史管理、LLM 交互循环编排 [仅主线程]
│   │   ├── context.cj                   # ContextManager：环境上下文持久化 + 版本迁移
│   │   ├── request.cj                   # RequestBuilder：构造 LLM 请求 (system prompt + context + history + tools)
│   │   ├── pty_agent.cj                 # PtyAgentLoop：PTY agentic 循环 (含调度/compact/上限)
│   │   ├── safety_fallback.cj           # SafetyFallback：LLM 未标记危险时的本地兜底检查
│   │   └── retry.cj                     # LLM 重试策略 (指数退避 + 错误分类)
│   │
│   ├── adapters/
│   │   ├── provider.cj                  # LLMProvider 接口 (chat / chatStream / chatWithTools)
│   │   ├── openai_compat.cj             # OpenAI 协议兼容实现 (含 response_format)
│   │   ├── anthropic.cj                 # Anthropic 协议实现 (含 tool_use)
│   │   ├── google.cj                    # Google 协议实现 (含 response_schema)
│   │   ├── sse.cj                       # SSE 协议解析器
│   │   └── structured_output.cj         # 各 Provider 的 Structured Output 适配封装
│   │
│   ├── infra/
│   │   ├── pty.cj                       # PTY 基础设施：posix_openpt/grantpt/unlockpt/fork/exec + master fd 读写 + TIOCSWINSZ
│   │   ├── spawn.cj                     # 普通子进程 spawn (stdout/stderr 捕获 + 超时 + 可中断)
│   │   ├── clipboard.cj                 # 剪贴板 (OSC 52 → Wayland → X11 → 降级)
│   │   ├── config.cj                    # 配置加载 (env → JSON → prompt)
│   │   ├── shell_rc.cj                  # Shell RC 管理 (install/uninstall, 注释标记包围)
│   │   ├── fs.cj                        # 文件工具 (JSON 读写 + flock LOCK_EX)
│   │   └── migration.cj                 # ContextMigration：逐版本数据迁移
│   │
│   └── util/
│       ├── prompt.cj                    # System prompt 模板常量 (主流程 + PTY agent)
│       └── json_schema.cj               # LLM 响应的 JSON Schema 定义 (用于 Structured Output)
```

### 2.1 包依赖关系

```
main ──→ tui ──→ core ──→ adapters (LLM 接口, 仅接口依赖)
  │        │       │
  │        │       ├──→ infra (pty, spawn, clipboard, fs, migration)
  │        │       └──→ util (prompt, json_schema)
  │        │
  │        └──→ infra (config, shell_rc)  [仅 install/uninstall 子命令时]
  │
  └──→ infra (config, migration)  [main 需要加载配置和迁移上下文]

types ←── 所有包 (零依赖，纯数据类型)
```

核心规则：
- `types/` 零依赖，被所有包引用
- `core/` 依赖 `adapters/` 的接口（不依赖具体实现）、`infra/`、`util/`
- `tui/` 依赖 `core/` 和 `infra/config`、`infra/shell_rc`
- `adapters/` 不依赖 `core/` 和 `tui/`
- `infra/` 不依赖 `core/`、`adapters/`、`tui/`
- `util/` 不依赖其他业务包

### 2.2 cjpm.toml

```toml
[package]
cjc-version = "1.1.0"
name = "termhelper"
description = "Linux 终端智能助手 — 自然语言驱动 Shell 操作"
version = "0.1.0"
output-type = "executable"

[dependencies]
ratatui = { path = "references/ratatui/cangjie-ratatui-sdk" }
```

---

## 3. 核心数据模型

### 3.1 LLM 结构化响应 (types/llm.cj)

LLM 响应通过各 Provider 的 **原生 Structured Output** 机制保证 JSON Schema 合规。
类型使用 `naivejson` 库的 `@JsonAdapter` 宏标注，编译器自动生成 `serialize()` / `deserialize()` / `toJsonSchema()`。

| Provider | 机制 |
|----------|------|
| OpenAI Compatible | `response_format: { type: "json_schema", json_schema: {...} }` |
| Anthropic | `tool_use` with a single tool whose `input_schema` is the response schema |
| Google | `response_mime_type: "application/json"` + `response_schema` |

当 Provider 不支持 `json_schema` 时（如 DeepSeek），自动降级为 `json_object` + 详细 prompt（含 few-shot examples）。
此时 JSON Schema 约束不再生效，改为通过 prompt 中的格式描述和示例保证输出结构。

```cangjie
enum LLMResponse {  // 不含 @JsonAdapter — payloaded enum 需手动 dispatch
    | Command(CommandData)
    | Investigate(InvestigateData)
    | Clarify(ClarifyData)
}

@JsonAdapter
class CommandData {
    var command: String = ""
    var explanation: Explanation = Explanation()
    var interactive: Bool = false
    var safety: SafetyInfo = SafetyInfo()
    var factEdits: ArrayList<FactEdit> = ArrayList<FactEdit>()
}

@JsonAdapter
class FactEdit {
    var op: String = ""        // add | update | delete
    var id: String = ""        // stable fact id, e.g. packageManager.pacman
    var oldText: String = ""   // required for update/delete, exact current text
    var newText: String = ""   // required for add/update
    var source: String = ""    // exact diagnostic command from current investigation
    var reason: String = ""
}

@JsonAdapter
class Explanation {
    var summary: String = ""
    var breakdown: ArrayList<BreakdownItem> = ArrayList<BreakdownItem>()
}

@JsonAdapter
class BreakdownItem {
    var component: String = ""
    var explanation: String = ""
}

@JsonAdapter
class SafetyInfo {
    var level: SafetyLevel = SafetyLevel.Safe
    var warnings: ArrayList<String> = ArrayList<String>()
}

@JsonAdapter
enum SafetyLevel {
    | Safe | Caution | Danger | Privilege
}

@JsonAdapter
class InvestigateData {
    var reason: String = ""
    var commands: ArrayList<DiagnosticCommand> = ArrayList<DiagnosticCommand>()
    var contextUpdates: HashMap<String, String> = HashMap<String, String>()  // deprecated compatibility field
}

@JsonAdapter
class DiagnosticCommand {
    var command: String = ""
    var rationale: String = ""
    @JsonIgnore var authorized: Bool = false   // 运行时字段，非 LLM 输出
}

@JsonAdapter
class ClarifyData {
    var question: String = ""
}
```

### 3.2 会话模型 (types/session.cj)

```cangjie
struct Message {
    role: MessageRole
    content: String
}

enum MessageRole {
    | System
    | User
    | Assistant
    | Tool                     // 诊断命令结果 / PTY agentic LLM 决策
}

struct EnvironmentContext {
    version: Int64             // 结构版本号，用于迁移
    facts: HashMap<String, EnvironmentFact>
    lastUpdated: Int64
}

struct EnvironmentFact {
    text: String               // 自然语言事实
    source: String             // initial local detection / diagnostic command
    lastVerified: Int64
}
```

> v4 起 context.json 只持久化 `facts`。发行版、包管理器、工具等都以稳定 ID 的自然语言 fact 保存；Shell 不持久化为 fact，而是在构造 prompt 时于 Known environment facts 之后动态注入。

### 3.3 PTY Agentic 工具集 (types/pty.cj)

```cangjie
// LLM 在 PTY agentic 循环中可选择的工具
enum PtyTool {
    | Write(String, String)              // 写入内容 + 理由
    | AskUser(String, Bool)              // 需要用户提供信息 (问题, 是否敏感)
    | Wait(Int64)                        // 等待指定毫秒数后继续
    | Exit(String)                       // 命令已完成 (摘要)
    | Interrupt(String)                  // 检测到异常，建议中断 (原因)
}

// PTY agentic 循环状态
enum PtyLoopState {
    | WaitingOutput                      // 等待 PTY 新输出
    | LLMDecision                        // LLM 正在决策
    | AwaitingConfirm(String, String)    // 等待用户确认 (待写入内容, 理由)
    | AwaitingUserInput(String, Bool)    // 等待用户输入 (LLM 的问题, 是否敏感)
    | Finished(PtyResult)                // 已完成
    | Interrupted(String)                // 已中断
    | Throttled(Int64)                   // 节流等待中 (剩余毫秒)
    | RoundLimitReached                  // 达到单次会话 LLM 调用上限
}

// PTY 执行结果（替代 v2 的 CommandResult 用于 PTY 场景）
struct PtyResult {
    exitCode: Int32
    output: String             // 合并的终端输出 (PTY master fd 不分离 stdout/stderr)
    summary: String            // LLM 生成的执行摘要
}
```

### 3.4 AppEvent — 后台任务 → TUI 通知

```cangjie
// 单向通道：后台任务 → TUI 主循环
enum AppEvent {
    | LLMChunk(String)                  // 流式响应片段 → Loading 屏实时更新
    | LLMDone(LLMResponse)              // 完整响应已解析
    | LLMError(String)                  // API 错误 (含重试耗尽)
    | LLMRetrying(Int64, String)        // 正在重试 (第n次, 原因)
    | SpawnOutput(String)               // spawn 输出行
    | SpawnDone(CommandResult)          // spawn 执行完毕
    | PtyScreenUpdate(String)           // PTY 虚拟终端全屏文本 (完整渲染帧)
    | PtyStateChange(PtyLoopState)      // PTY agentic 循环状态变更
    | PtyOverlayUpdate(PtyOverlayData)  // PTY overlay 面板内容更新
    | ClipboardDone                     // 复制完成
    | ModifySubmitted(String)           // 用户提交修改指示
    | ContextSaved                      // 上下文已持久化
}

struct CommandResult {
    exitCode: Int32
    stdout: String
    stderr: String
}

// PTY overlay 面板数据
struct PtyOverlayData {
    mode: PtyMode                      // Confirm / FullAuto
    llmDecision: Option<String>        // LLM 当前决策描述
    pendingWrite: Option<String>       // 待确认的写入内容
    pendingReason: Option<String>      // 待确认的写入理由
    roundCount: Int64                  // 当前 LLM 调用轮次
    maxRounds: Int64                   // 最大轮次
}

enum PtyMode {
    | Confirm                          // 默认模式：逐次确认
    | FullAuto                         // 全自动模式
}
```

---

## 4. PTY Agentic 循环

### 4.1 设计动机

与 v2 相同：v1 的 PTY 循环 LLM 只返回 write/done 两种 action，扩展性差。实际场景需要 write/ask_user/wait/exit/interrupt 五种工具。v3 在此基础上增加事件驱动调度、compact buffer、调用上限和敏感输入控制。

### 4.2 循环流程

```
PtyAgentLoop.start(command)
  │
  ├── infra/pty.cj: 创建 PTY (相同于真实终端大小 W×H)，spawn 子进程
  │
  ▼
┌─────────────────────────────────────────────────────────┐
│  agentic 循环 (core/pty_agent.cj)                        │
│                                                         │
│  var roundCount = 0                                     │
│  var maxRounds = 50                                     │
│  var scheduler = PtyDecisionScheduler()                 │
│  var llmContext = PtyLlmContextBuffer()                 │
│                                                         │
│  while roundCount < maxRounds:                          │
│    ┌──────────────────────────────────────────────┐     │
│    │ 1. 读 PTY master fd (非阻塞)                  │     │
│    │    → 追加到原始输出缓冲区                      │     │
│    │    → 更新虚拟终端屏幕状态 (同真实终端大小)     │     │
│    │    → 归一化终端文本 (处理 \r/ANSI 进度条)       │     │
│    │    → append 到 LLM compact buffer              │     │
│    │    → 发送 PtyScreenUpdate(全屏文本) 到 TUI    │     │
│    └──────────────┬───────────────────────────────┘     │
│                   │                                     │
│    ┌──────────────▼───────────────────────────────┐     │
│    │ 2. 如果子进程已退出:                           │     │
│    │    → PtyTool.Exit(摘要) + break              │     │
│    └──────────────┬───────────────────────────────┘     │
│                   │                                     │
│    ┌──────────────▼───────────────────────────────┐     │
│    │ 3. 调度检查:                                  │     │
│    │    if 无新输出且子进程未退出: continue         │     │
│    │    if 未到 Wait/退避设置的 nextEligibleAt:     │     │
│    │      continue                                 │     │
│    │    if 输出仍在 quiet window 内且未到硬上限:    │     │
│    │      continue                                 │     │
│    └──────────────┬───────────────────────────────┘     │
│                   │                                     │
│    ┌──────────────▼───────────────────────────────┐     │
│    │ 4. 构造 LLM tool-calling 请求:                │     │
│    │    system: PTY agent prompt                  │     │
│    │    context: 命令 + 最近历史决策 (脱敏后)       │     │
│    │    user: compact checkpoint + recent + delta   │     │
│    │    tools: [write, ask_user, wait,             │     │
│    │            exit, interrupt]                   │     │
│    │    tool_choice: "required"                    │     │
│    └──────────────┬───────────────────────────────┘     │
│                   │                                     │
│    ┌──────────────▼───────────────────────────────┐     │
│    │ 5. LLM 返回 PtyTool 选择                      │     │
│    │    roundCount += 1                            │     │
│    │    更新 lastDecisionAt / lastSentOffset        │     │
│    └──────────────┬───────────────────────────────┘     │
│                   │                                     │
│        ┌──────────┼──────────┬──────────┬──────────┐    │
│        ▼          ▼          ▼          ▼          ▼    │
│      Write     AskUser     Wait      Exit    Interrupt  │
│        │          │          │          │          │     │
│  ┌─────▼────┐ ┌──▼────┐ ┌──▼────┐ ┌───▼───┐ ┌──▼──┐   │
│  │默认模式:  │ │sensitive│ │sleep │ │展示   │ │展示 │   │
│  │Awaiting  │ │=true→ │ │duration│ │摘要   │ │原因 │   │
│  │Confirm   │ │密码   │ │_ms后  │ │结束   │ │询问 │   │
│  │          │ │遮罩   │ │继续   │ │循环   │ │是否 │   │
│  │全自动:   │ │输入   │ │       │ │       │ │中断 │   │
│  │直接写入  │ │结果   │ │       │ │       │ │     │   │
│  │          │ │脱敏后│ │       │ │       │ │     │   │
│  │          │ │回传   │ │       │ │       │ │     │   │
│  │          │ │LLM    │ │       │ │       │ │     │   │
│  └─────────┘ └───────┘ └───────┘ └───────┘ └──────┘   │
│                   │                                     │
│            继续下一轮循环                                 │
│                                                         │
│  if roundCount >= maxRounds:                            │
│    → PtyStateChange(RoundLimitReached)                  │
│    → 暂停循环，询问用户：继续/中断/切换手动               │
└─────────────────────────────────────────────────────────┘
```

### 4.3 调度与成本控制

| 控制项 | 值 | 说明 |
|--------|-----|------|
| 事件驱动调用 | 仅在有新输出、用户输入、工具写入或子进程退出后考虑调用 | 静默期间不按时间空转调用 LLM |
| 输出静默窗口 | 默认 800ms | 输出仍在刷新时先等待稳定，避免进度条/刷屏期间高频调用 |
| 持续输出硬上限 | 默认 5000ms | 输出一直不停止时最多等待该时长后调用一次 |
| LLM compact buffer | 超过阈值后一次性 compact，保留尾部并继续 append | 不使用滑动窗口，避免频繁搬移历史和破坏缓存局部性 |
| 终端文本归一化 | 处理 `\r`、`\b`、`ESC[K`、`ESC[0G` 等覆盖语义 | 防止进度条在 LLM 上下文中堆成重复历史 |
| 单次会话最大轮次 | 50 | 达到后暂停，询问用户是否继续 |
| Wait 工具时长范围 | LLM 建议值，系统 clamp 到 [500ms, 30s] | 设置 `nextEligibleAt`，到时后仍需满足“有新输出或进程退出” |
| 用量追踪 | 每轮记录 prompt_tokens + completion_tokens，overlay 面板展示累计值 | 用户知情 PTY 会话的 API 成本 |

详细设计见 [PTY Agent Token 控制设计方案](./pty-agent-token-control-design.md)。本文档只保留架构级约束：PTY agent 不再使用“最小间隔 + 最小新增字节阈值”的旧节流模型；LLM 调用必须由事件调度器放行，且发送给 LLM 的文本必须来自 compact 后的终端语义归一化 buffer。

### 4.4 PTY 输出渲染策略（v3 变更：全屏底层 + overlay）

v2 方案将 PTY 输出 diff 作为 ratatui 组件内容渲染，存在 ANSI 序列与 ratatui 绘制冲突的风险。

v3 采用**全屏底层 + 浮动 overlay** 方案：

```
┌──────────────────────────────────────────┐
│  真实终端 (W×H)                           │
│                                          │
│  ┌────────────────────────────────────┐  │
│  │ PTY 虚拟终端全屏渲染 (W×H)          │  │
│  │ (将虚拟终端缓冲区每一单元格渲染为     │  │
│  │  ratatui 的 Span，保留前景/背景色    │  │
│  │  和基本属性如粗体/下划线)            │  │
│  │                                    │  │
│  │ $ sudo apt update                  │  │
│  │ [sudo] password for user:          │  │
│  │ Hit:1 http://archive.ubuntu.com... │  │
│  │ Reading package lists... Done      │  │
│  │                                    │  │
│  └────────────────────────────────────┘  │
│                                          │
│  ┌────────────────────────────────────┐  │
│  │ Overlay 面板 (底部固定区域, ~3-5行)  │  │
│  │ ────────────────────────────────── │  │
│  │ 模式: [默认·逐次确认] 轮次: 3/50    │  │
│  │ LLM决策: 检测到密码提示, 请求用户   │  │
│  │          输入sudo密码               │  │
│  │ [确认写入] [拒绝] [切换到全自动]     │  │
│  └────────────────────────────────────┘  │
└──────────────────────────────────────────┘
```

实现要点：
- **虚拟终端大小**：创建 PTY 时通过 `TIOCSWINSZ` 设置 slave 窗口大小 = 真实终端行列数（从 ratatui 获取）
- **ANSI → ratatui Spans**：虚拟终端缓冲区的每个单元格（字符 + fg/bg 颜色 + 粗体/下划线/反色属性）映射为 ratatui `Span`，按行组织为 `Paragraph` 渲染
- **Overlay 面板**：浮动在底层 PTY 内容之上，占据底部固定行数（约 3~5 行），使用 ratatui 的 `Clear` + `Block` + `Paragraph` 绘制
- **滚动**：当 PTY 输出超过终端行数时，虚拟终端缓冲区维护滚动回视区，默认展示最底部（最新输出）；用户可通过键盘向上滚动查看历史
- **信号处理**：SIGWINCH 到达时更新虚拟终端大小 + 通过 ioctl 更新 PTY slave 窗口大小，触发重新渲染

### 4.5 敏感输入处理

当 `PtyTool::AskUser(question, sensitive=true)` 时：

1. TUI 使用 `text_input.cj` 的密码遮罩模式（回显 `***` 或无回显）
2. 用户输入的密码写入 PTY 后，不将密码原文追加到 LLM 对话历史
3. 下一轮 LLM 请求中的历史决策记录为：`AskUser("请输入sudo密码", sensitive=true) → 用户已输入 [REDACTED]`
4. PTY 输出中如果检测到密码回显（某些程序会回显输入），在发送给 LLM 的 diff 文本中替换为 `[PASSWORD_REDACTED]`

### 4.6 LLM PTY Agent System Prompt 要点

```
你是一个终端操作代理。你将收到 PTY 的输出，需要选择工具来响应当前状态。

可用工具：
- write(content, reason): 向终端写入内容。默认会请求用户确认。
- ask_user(question, sensitive): 需要用户提供信息。
  当需要密码/密钥/Token 时，sensitive 设为 true。
- wait(duration_ms): 输出不完整，等待 duration_ms 毫秒后继续。
  建议范围 500-30000ms。如等待时间不确定，建议 3000ms。
- exit(summary): 命令执行完成，提供执行摘要。
- interrupt(reason): 检测到异常，建议中断。

规则：
- 看到 password/passphrase/secret/token 提示时，使用 ask_user，sensitive=true
- 看到 [Y/n] 确认提示时，使用 write("Y\n", ...) 或 write("n\n", ...)
- 检测到 "Permission denied"、"command not found"、"No such file" 等错误时，使用 interrupt
- 输出明显不完整时（如下载进度条中途），使用 wait 等待更多输出
- 不确定是否完成时，使用 wait 而非立即 exit

用户的原始需求：（）
```

---

## 5. 关键流程

### 5.1 主交互流程

```
用户输入: ?? 删除所有std开头的文件夹
                  │
┌─────────────────▼────────────────────────────────────┐
│ main.cj                                              │
│  1. 解析命令行参数:                                    │
│     识别保留词: --install / --uninstall / --help      │
│     其余: query = "删除所有std开头的文件夹"             │
│  2. 子命令分发:                                       │
│     --install  → infra/shell_rc.cj.install()         │
│     --uninstall→ infra/shell_rc.cj.uninstall()       │
│     --help     → 打印帮助                             │
│     其他       → 进入查询流程 ↓                        │
│  3. infra/config.cj.load() → Config                  │
│  4. infra/migration.cj.migrate() → 迁移旧数据         │
│  5. core/context.cj.load() → EnvironmentContext      │
│  6. 创建 Channel<AppEvent>                           │
│  7. 创建 Session(llmClient, envContext) [主线程持有]   │
│  8. 主线程: session.append(User, query)               │
│  9. 后台 spawn: llmClient.chatStream(...)             │
│     (后台任务通过 channel 回传 LLMChunk/LLMDone/LLM*)  │
│ 10. 注册信号处理器 (SIGINT/SIGTERM/SIGHUP/SIGWINCH)    │
│ 11. TUI.init() → 进入主循环                           │
└─────────────────┬────────────────────────────────────┘
                  │
┌─────────────────▼────────────────────────────────────┐
│ TUI 主循环 (tui/tui.cj)                               │
│                                                      │
│  let screen = Screen::Loading                        │
│  while screen != Exit:                               │
│    // 1. 检查后台事件 (非阻塞)                         │
│    match channel.tryRecv():                          │
│      Some(AppEvent.LLMChunk(chunk)) →                │
│        loading_screen.append_streaming_text(chunk)    │
│      Some(AppEvent.LLMDone(response)) →              │
│        session.append(Assistant, response) // 主线程  │
│        screen = dispatch(response)                   │
│      Some(AppEvent.LLMError(err)) →                  │
│        screen = Screen::Error(err, retryable)        │
│      Some(AppEvent.LLMRetrying(n, reason)) →         │
│        loading_screen.show_retry(n, reason)          │
│      Some(AppEvent.SpawnOutput(line)) →              │
│        execute_screen.append(line)                   │
│      Some(AppEvent.SpawnDone(result)) →              │
│        execute_screen.show_result(result)            │
│      Some(AppEvent.PtyScreenUpdate(full_text)) →     │
│        pty_screen.update_terminal_layer(full_text)    │
│      Some(AppEvent.PtyStateChange(state)) →          │
│        pty_screen.update_state(state)                │
│      Some(AppEvent.PtyOverlayUpdate(data)) →         │
│        pty_screen.update_overlay(data)               │
│      Some(AppEvent.ModifySubmitted(text)) →          │
│        session.append(User, text) // 主线程追加       │
│        screen = Screen::Loading                      │
│        后台 spawn: 新一轮 LLM 调用                     │
│      ...                                            │
│      None → ()  // no event                          │
│                                                      │
│    // 2. 读取键盘事件 (非阻塞)                         │
│    match pollEvent(50ms):                            │
│      Some(event) → screen.handle_input(event)        │
│      None → ()                                      │
│                                                      │
│    // 3. 渲染                                        │
│    screen.draw()                                    │
└─────────────────────────────────────────────────────┘
```

### 5.2 LLM 调用流程

```
Session.buildRequest()                  [core/request.cj]
  ├── System Prompt (util/prompt.cj)
  ├── JSON Schema (util/json_schema.cj, 用于 Structured Output)
  ├── EnvironmentContext (JSON 序列化)
  └── Messages[] (对话历史, 仅主线程读)
        │
        ▼
LLMProvider.chatStream(request, onChunk)  [adapters/provider.cj]
  ├── HTTP POST + Structured Output 配置
  │   (OpenAI: response_format, Anthropic: tool_use 单工具,
  │    Google: response_schema)
  ├── 超时控制: connect_timeout=10s, read_timeout=60s, idle_timeout=30s
  ├── SseParser 逐块解析 resp.body           [adapters/sse.cj]
  └── onChunk → channel.send(AppEvent.LLMChunk(...))
        │
        ▼
  流结束 → StructuredOutput 校验             [adapters/structured_output.cj]
         → 反序列化到 LLMResponse
         → channel.send(AppEvent.LLMDone(response))
```

### 5.3 流式加载显示

Loading 屏实时展示 LLM 流式输出的文本内容：

- 每个 `LLMChunk` 追加到 Loading 屏文本缓冲区
- 使用 ratatui `Paragraph` + 自动换行渲染
- 与 spinner 动画共享屏幕空间（spinner 在上方，流式文本在下方可滚动区域）
- LLM 调用结束后，Loading 屏文本保留在内存中（可回看），但不影响后续 Screen 切换

### 5.4 环境调查流程

```
LLM 返回 type: "investigate"
  │
  ▼
TUI 切换到 Prompt 屏 (PromptMode::Investigate)
  ├── 展示调查理由 (reason)
  ├── 展示诊断命令列表 (每条附 rationale)
  └── 用户逐条/批量授权
        │
        ▼
  infra/spawn.cj 执行授权命令 (每命令 5s 超时)
        │
        ▼
  结果 → [主线程] session.append(Tool, result)
  [主线程] context.update(newInfo)
  发起新一轮 LLM 调用 → 回到 Loading
```

### 5.5 普通执行流程

```
用户选择 "运行" (interactive: false)
  │
  ▼
TUI 切换到 Execute 屏
  ├── 用户可中断 (SIGINT → kill 子进程)
  ├── infra/spawn.cj: spawn 子进程 (配置的超时时间)
  ├── stdout/stderr 逐行 → channel.send(AppEvent.SpawnOutput(...))
  └── 进程退出/超时/被中断 → channel.send(AppEvent.SpawnDone(result))
  │
  ▼
Execute 屏展示最终结果 (退出码 + 输出)
用户可返回 Result 屏修改或退出
```

---

## 6. TUI 状态机

### 6.1 Screen 定义

```cangjie
enum Screen {
    | Loading                          // spinner + 流式 LLM 文本
    | Result(CommandData)              // 命令 + 说明 + 安全警告 + 选项菜单
    | Execute(ExecuteState)            // 普通 spawn 执行，实时输出
    | PtyAgentic(PtyLoopState)         // PTY agentic 循环，全屏 PTY + overlay
    | Prompt(PromptMode)               // investigate / clarify / modify
    | Error(String, Bool)              // 错误信息 + 是否可重试
}

enum PromptMode {
    | Investigate(InvestigateData)     // 调查授权
    | Clarify(ClarifyData)             // LLM 澄清提问
    | Modify(String)                   // 用户修改 (当前命令文本供参考)
}

struct ExecuteState {
    command: String
    output: ArrayList<String>
    exitCode: Option<Int32>
    running: Bool
}
```

### 6.2 状态转换

```
                    ┌──────────┐
                    │  START   │
                    └────┬─────┘
                         │
                         ▼
                   ┌──────────┐
              ┌───→│ LOADING  │←──────────────────────────┐
              │    │(流式文本) │                           │
              │    └────┬─────┘                           │
              │         │ LLM 响应到达                     │
              │         ▼                                 │
              │  ╔══════════════╗                         │
              │  ║  type 分发   ║                         │
              │  ╚═══╤══╤══╤══╝                         │
              │      │  │  │                            │
              │ command │  │                            │
              │      │  │  │                            │
              │      ▼  ▼  ▼                            │
              │  ┌──────┐┌──────────┐                   │
              │  │RESULT││ PROMPT   │                   │
              │  └──┬─┬─┘│          │                   │
              │     │ │  │ Investigate                  │
              │     │ │  │ Clarify                      │
              │     │ │  │ Modify                       │
              │     │ │  └────┬─────┘                   │
              │     │ │       │                         │
              │     │ │  用户操作 (授权/回答/提交修改)     │
              │     │ │       │                         │
              │     │ │       └──→ 新一轮 LLM 调用 ───────┘
              │     │ │
              │     │ └── 修改 → Prompt(Modify) → 提交
              │     │              → Loading ──────────┘
              │     │
              │     ├── 运行 → ┌─────────┐
              │     │          │ EXECUTE │ → 完成/中断 → RESULT
              │     │          └─────────┘
              │     │
              │     ├── 运行并接管 → ┌────────────┐
              │     │               │ PTY_AGENTIC│ → 完成/中断 → RESULT
              │     │               └────────────┘
              │     │
              │     └── 复制 → 退回到 Shell
              │
              └── LLM 错误 → ┌───────┐
                             │ ERROR │ → 重试 → LOADING
                             └───────┘ → 退出
```

---

## 7. 并发模型

### 7.1 线程/任务模型

```
┌──────────────────────────────────────────────────────┐
│  Main Thread (TUI) — 唯一持有 Session 的线程           │
│  - ratatui poll_event + draw 循环                     │
│  - 键盘输入 → 直接调用 screen.handle_input()          │
│  - Channel.tryRecv() → 非阻塞接收后台事件              │
│    · LLMDone → session.append() (主线程安全)          │
│    · ModifySubmitted → session.append() + 新 LLM 调用  │
│  - 严禁阻塞 I/O                                       │
│  - 信号处理器在此线程注册                              │
└──────────┬───────────────────────────────────────────┘
           │ Channel<AppEvent> (单向: 后台 → TUI)
           │
    ┌──────┴──────────────────────────────┐
    │                                      │
┌───▼──────────────┐         ┌────────────▼──────────┐
│ LLM Task         │         │ Executor Task         │
│ (后台 spawn)      │         │ (后台 spawn)           │
│                  │         │                       │
│ - HTTP 请求      │         │ - spawn 子进程         │
│ - SSE 流式解析   │         │ - PTY I/O 读写         │
│ - Structured     │         │ - PTY agentic 循环     │
│   Output 校验    │         │   (调度/compact/上限)   │
│ - 重试逻辑       │         │ → channel.send()      │
│ → channel.send() │         │                       │
└──────────────────┘         └───────────────────────┘
```

**线程安全核心约定：**
- Session（对话历史）仅主线程持有和修改
- 后台 LLM 任务不持有 Session 引用；它接收 RequestBuilder 构造的不可变请求快照
- 后台任务产出的结果（LLMResponse、错误等）通过 Channel 发送，主线程在 tryRecv 时追加到 Session
- 这意味着 LLM 流式响应完成到 Session 实际追加之间存在一帧的延迟（≤50ms），对交互体验无影响

### 7.2 上下文文件并发安全

```
ContextManager (core/context.cj) → infra/fs.cj
  ├── 读 context.json:  flock LOCK_EX (排他锁, 全程持有)
  │   → 版本检查 → 如需迁移则执行 → 反序列化 → 释放锁
  └── 写 context.json:  flock LOCK_EX (排他锁, 全程持有)
      → 序列化 → 写入 → fsync → 释放锁
```

> v2 的读写分离锁（读共享、写互斥）存在读-修改-写竞争：两实例同时读 → 各自修改 → 后写者覆盖前者。v3 改为全程排他锁，因为 termhelper 为短生命周期工具，锁竞争概率低，数据正确性优先级高于读并发。

---

## 8. 配置与安装

### 8.1 配置优先级

```
API Key 读取顺序:
  1. Provider 专属环境变量（ANTHROPIC_API_KEY 仅当 provider=anthropic 时生效，
     GOOGLE_API_KEY 仅当 provider=google 时生效）
  2. 通用环境变量 (LLM_API_KEY，其次 OPENAI_API_KEY)
  3. ~/.config/termhelper/config.json → llm.api_key 字段
  4. TUI 首次运行交互式提示输入

LLM Provider 选择:
  1. config.json → provider 字段 (openai_compat / anthropic / google)
  2. 默认 openai_compat

structured_output_mode:
  - "auto"（默认）: 先尝试 json_schema，若 Provider 不支持（HTTP 400）自动降级为
    json_object + 详细 prompt（含 few-shot examples）
  - "json_object": 跳过 json_schema 尝试，直接使用 json_object 模式
```

### 8.2 config.json

```jsonc
{
  "version": 1,
  "provider": "openai_compat",
  "llm": {
    "api_key": "",
    "base_url": "https://api.openai.com/v1",
    "model": "gpt-4o",
    "timeout_sec": 60,
    "connect_timeout_sec": 10,
    "idle_timeout_sec": 30,
    "structured_output_mode": "auto"
  },
  "execution": {
    "spawn_timeout_sec": 300,
    "pty_default_mode": "confirm",
    "pty_max_rounds": 50,
    "pty_min_interval_ms": 2000,
    "pty_quiet_window_ms": 800,
    "pty_max_wait_after_output_ms": 5000,
    "pty_llm_compact_threshold_bytes": 131072,
    "pty_llm_compact_keep_bytes": 24576,
    "pty_decision_history_limit": 8,
    "pty_context_max_bytes": 32768
  },
  "retry": {
    "max_retries": 3,
    "base_delay_ms": 1000,
    "max_delay_ms": 16000
  }
}
```

### 8.3 命令行接口

```
termhelper <自然语言查询>      执行查询，启动 TUI
termhelper --install           安装 Shell 集成 (alias/def 写入 RC 文件)
termhelper --uninstall         卸载 Shell 集成 (从 RC 文件移除)
termhelper --help              打印帮助信息
```

**子命令与查询的区分规则：**
- 以 `--` 为前缀的参数精确匹配保留词列表（`install`、`uninstall`、`help`）
- 其余所有参数拼接为自然语言查询字符串
- 用户输入 `?? --install` 时，Shell 将 `--install` 作为参数传入，main.cj 识别为安装子命令
- 用户输入 `?? install something` 时，无 `--` 前缀 → 作为查询 "install something" 处理

### 8.4 安装/卸载

```
termhelper --install
  1. 检测 Shell (SHELL 环境变量)
  2. 在 RC 文件中追加注释标记包围的 alias/def：
     # >>> termhelper >>>
     alias '??'='termhelper'
     # <<< termhelper <<<
  3. 创建 ~/.config/termhelper/ (权限 0700)
  4. 提示 source RC 或重启 Shell

termhelper --uninstall
  1. 定位 RC 文件中 # >>> termhelper >>> 和 # <<< termhelper <<< 之间的内容
  2. 删除整个标记区块（含标记注释行）
  3. 询问是否删除 ~/.config/termhelper/ (默认保留)
```

> 使用注释标记包围而非简单字符串匹配，即使用户手动修改了 alias 行，卸载仍能安全定位并删除整个区块。标记注释对各 Shell 均有效（bash/zsh/fish 用 `#`，nushell 用 `#`）。

### 8.5 冷启动性能分析

**目标：** 从 `??` 触发到 TUI 界面就绪 ≤ 2s（NFR-01）

**启动路径分析：**

| 步骤 | 操作 | 预估耗时 |
|------|------|----------|
| 1 | 进程启动 + 加载动态库 (ratatui binding) | ~200ms |
| 2 | 加载 config.json | ~5ms (本地文件读取) |
| 3 | 迁移检查 + 加载 context.json | ~10ms (flock + JSON 解析) |
| 4 | 初始化 ratatui (alternate screen + raw mode) | ~50ms |
| 5 | 注册信号处理器 | <1ms |
| 6 | 渲染 Loading 屏首帧 | ~10ms |
| **合计 (不含网络)** | | **~280ms** |

**满足 2s 约束的关键前提：**
- ratatui binding 的动态库加载时间在合理范围内（需实现阶段验证）
- TUI 初始化与 LLM 调用解耦：Loading 屏首帧渲染完成后立即展示，LLM 调用在后台进行
- 用户感知的"启动完成"是 Loading 屏出现的那一刻（~300ms），而非 LLM 响应返回

---

## 9. 信号处理与生命周期

### 9.1 信号处理器

| 信号 | 处理器行为 |
|------|-----------|
| SIGINT | Loading 态：取消当前 LLM 调用 → Error 屏。Execute 态：kill 子进程 → 展示部分输出。PtyAgentic 态：中断 PTY → 询问是否退出。Result/Prompt/Error 态：退出 TUI |
| SIGTERM | 同 SIGINT，优雅退出（恢复终端 + 清理 PTY + 持久化上下文） |
| SIGHUP | 终端断开，快速退出（恢复终端模式，尽力清理 PTY） |
| SIGWINCH | 1) 更新 ratatui 终端大小 2) 通过 `ioctl(TIOCSWINSZ)` 更新所有活跃 PTY slave 的窗口大小 3) 触发当前 Screen 重绘 |

### 9.2 崩溃恢复

```cangjie
// main.cj 启动时注册
panic_hook: {
    // 1. 恢复终端模式 (raw → cooked)
    // 2. 退出 alternate screen
    // 3. 遍历活跃 PTY，发送 SIGHUP 给子进程组
    // 4. 打印崩溃信息到 stderr
}
```

### 9.3 正常退出流程

```
用户按 Esc/q 或选择退出
  │
  ▼
1. 检查是否有活跃的后台任务 (LLM 调用 / spawn / PTY)
2. 如有：
   ├── 提示用户确认
   └── 取消/中断后台任务
3. context.save() → 持久化环境上下文
4. 退出 alternate screen
5. 恢复终端模式 (raw → cooked)
6. 进程退出
```

---

## 10. 错误处理

| 场景 | 处理 |
|------|------|
| LLM API 不可达 (连接超时/ DNS失败) | Error 屏："无法连接到 LLM 服务" — 重试/退出 |
| LLM API 返回 401/403 | Error 屏："API Key 无效或无权访问" — 检查配置/退出（不可重试） |
| LLM API 返回 429 | 自动重试（等待 Retry-After 头或指数退避） |
| LLM API 返回 5xx | 自动重试（指数退避，最多 3 次） |
| Structured Output 校验失败 | Error 屏："LLM 返回格式异常" — 展示原始响应 — 重试/退出 |
| LLM 流式响应中途断开 | Error 屏："连接中断" — 重试/退出 |
| LLM 调用超时 (idle_timeout) | Error 屏："LLM 响应超时" — 重试/退出 |
| 诊断命令执行失败 | stderr 作为 Tool 消息返回给 LLM，LLM 自行决策替代方案 |
| 用户命令执行失败 (exitCode != 0) | Execute 屏展示退出码 + stderr，可返回 Result 屏修改 |
| 子进程执行超时 | Execute 屏展示部分输出 + 继续等待/中断选项 |
| PTY 创建失败 | 降级为"仅复制" + 提示 |
| PTY agentic 达到轮次上限 | PtyAgentic 屏暂停 + 询问用户继续/中断/切手动 |
| 剪贴板工具全部不可用 | 展示命令文本 + 提示安装 (wl-clipboard / xclip / 终端不支持 OSC 52) |
| 配置文件损坏 | 默认配置 + 警告 |
| 上下文文件损坏或版本不兼容 | 丢弃，重新调查 |
| 上下文迁移失败 | 丢弃旧数据 + 警告 + 重新调查 |
| 终端大小变为 0×0 | 忽略 SIGWINCH，等待下一次有效大小 |

**原则：任何错误不崩溃退出 TUI，始终给用户可操作的回退路径。崩溃时通过 panic hook 恢复终端。**

---

## 11. LLM 重试策略

### 11.1 重试决策表

| 错误类型 | 可重试 | 最大次数 | 退避策略 | 备注 |
|----------|--------|----------|----------|------|
| 连接超时 | 是 | 3 | 指数退避 | 可能临时网络问题 |
| 读取超时/空闲超时 | 是 | 2 | 指数退避 | 可能是模型卡住 |
| DNS 解析失败 | 是 | 2 | 固定 2s | 可能临时 DNS 问题 |
| HTTP 429 Rate Limit | 是 | 3 | Retry-After 优先，否则指数退避 | 尊重服务端限流 |
| HTTP 5xx (502/503/504) | 是 | 3 | 指数退避 | 服务端临时故障 |
| HTTP 500 | 是 | 1 | 固定 1s | 可能是模型内部错误 |
| HTTP 400 Bad Request | 否 | 0 | — | 请求参数错误 |
| HTTP 401 Unauthorized | 否 | 0 | — | API Key 无效 |
| HTTP 403 Forbidden | 否 | 0 | — | 无权访问 |
| Structured Output 校验失败 | 是 | 1 | 固定 0s | 模型偶发不遵守 schema |
| SSE 流解析错误 | 否 | 0 | — | 数据损坏，建议重试整次调用 |

### 11.2 指数退避公式

```
delay = min(base_delay_ms * 2^(attempt-1), max_delay_ms)
// 默认: 1s → 2s → 4s → 8s → 16s (cap)
```

### 11.3 重试实现

重试逻辑封装在 `core/retry.cj`，供 LLM Task 使用：

```
retry.withBackoff(
    maxRetries: config.retry.max_retries,
    baseDelay: config.retry.base_delay_ms,
    maxDelay: config.retry.max_delay_ms,
    isRetryable: (error) => classify(error),
    onRetry: (attempt, reason) => channel.send(LLMRetrying(attempt, reason)),
    body: () => llmClient.chatStream(request)
)
```

PTY agentic 循环中单轮 LLM 调用的重试：最多 2 次，失败后暂停循环，通过 `PtyStateChange` 通知 TUI 询问用户。

---

## 12. 安全边界

```
                用户信任边界
┌───────────────────────────────────────────────┐
│  用户明确授权后才能执行:                        │
│  - 诊断命令 (Prompt 屏逐条/批量授权)            │
│  - 危险/提权命令 (二次确认)                     │
│  - PTY write 操作 (默认模式逐次确认)            │
│                                               │
│  用户需知情:                                   │
│  - 命令的风险等级和具体警告                      │
│  - PTY agentic 循环中 LLM 的决策和理由          │
│  - PTY agentic 的 LLM 调用轮次和累计 token 用量  │
│  - 全自动模式的状态 (持续可见的状态提示)         │
│                                               │
│  系统保证:                                     │
│  - API Key 存储在环境变量或 0600 配置文件        │
│  - context.json 不存储敏感信息                  │
│  - 对话历史不持久化 (仅内存)                    │
│  - 全自动模式可随时切回默认模式或中断            │
│  - SafetyFallback 仅在 LLM 未标记时兜底         │
│  - ask_user(sensitive=true) 的输入在 TUI 遮罩    │
│    且不进入 LLM 上下文                          │
│  - PTY 输出中的密码回显在发送 LLM 前脱敏         │
│  - Shell RC 文件安装仅追加标记区块，不修改其他配置│
│  - 崩溃/信号退出时恢复终端模式                   │
└───────────────────────────────────────────────┘
```

---

## 13. 待实现阶段验证

| 项 | 说明 | 影响范围 |
|----|------|----------|
| ratatui binding 能力验证 | 全屏接管、键盘事件、颜色渲染、启动性能 | tui/ 全部 |
| ratatui alternate screen 开销 | 冷启动中 alternate screen 切换的耗时 | main.cj |
| nushell def 参数展开语法 | `...$args` 兼容性 | infra/shell_rc.cj |
| nushell `#` 注释兼容性 | RC 标记注释在 nushell 中是否有效 | infra/shell_rc.cj |
| Cangjie FFI + libc | posix_openpt/fork/exec/TIOCSWINSZ 的 FFI 声明 | infra/pty.cj |
| `stdx.net.http` 流式读取 | HTTPS + 长连接行为 + connect/read timeout 支持 | adapters/sse.cj |
| `stdx.net.http` 超时控制 | 是否支持连接超时和读取超时独立配置 | adapters/provider 实现 |
| 仓颉并发原语 | Channel / spawn 的实际 API | core/session.cj, main.cj |
| 虚拟终端 ANSI 解析器 | v1 降级为行缓冲 vs 完整虚拟终端解析器的实现成本 | core/pty_agent.cj, tui/screens/pty_agentic.cj |
| OSC 52 终端支持检测 | 如何检测当前终端模拟器是否支持 OSC 52 | infra/clipboard.cj |
| 信号处理器注册 | 仓颉中信号处理的 API (signal/SigAction) | tui/signal.cj |
| 仓颉 panic hook | 仓颉中注册全局 panic handler 的 API | main.cj |
| Structured Output 各 Provider 支持 | OpenAI/Anthropic/Google 的结构化输出 API 差异 | adapters/structured_output.cj |
| `context.json` 迁移链 | v1→v2→...→vn 的迁移函数注册和执行机制 | infra/migration.cj |
