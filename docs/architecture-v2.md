# 智能终端助手 架构设计 v2

> 基于 [需求分析说明书 v5](./requirements-final.md) 和 [技术选型](./tech-selection.md)
> v1 审议结论：事件总线过度设计、LLM/执行器分层不当、PTY 应属基础设施、PTY 执行应改为 agentic tool-calling 循环

## 1. 架构总览

### 1.1 分层架构

```
┌──────────────────────────────────────────────────────────────┐
│                      入口 (main.cj)                           │
│  命令行解析 → 配置加载 → 上下文加载 → 启动 TUI → 进入主循环     │
└──────────────────────────┬───────────────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────────────┐
│                      TUI 层 (tui/)                            │
│  ┌──────────┐  ┌─────────────┐  ┌──────────────────────────┐ │
│  │  Screen  │  │  Components  │  │  Theme / Input           │ │
│  │  Router  │  │  (可复用组件) │  │  (颜色/键盘处理)          │ │
│  └──────────┘  └─────────────┘  └──────────────────────────┘ │
│                                                                 │
│  Screen: Loading → Result → Execute/PtyAgentic/Prompt/Error    │
│  主循环: poll_event → 分发键盘 → 检查后台通道 → draw           │
└──────────────────────────┬───────────────────────────────────┘
                           │ Channel<AppEvent> (后台→TUI)
                           │ 直接调用 (TUI→Core)
┌──────────────────────────▼───────────────────────────────────┐
│                      核心层 (core/)                            │
│  ┌────────────┐  ┌────────────┐  ┌─────────────────────────┐ │
│  │  Session   │  │  Context   │  │  PtyAgentLoop           │ │
│  │  (会话编排) │  │  Manager   │  │  (PTY agentic 循环)     │ │
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
│  ├─ OpenAICompat    │    │  │  Pty     │ │  Spawn        │  │
│  ├─ Anthropic       │    │  │  (创建/  │ │  (子进程执行)   │  │
│  └─ Google          │    │  │   读写/  │ └───────────────┘  │
│  ├─ SseParser       │    │  │   销毁)  │ ┌───────────────┐  │
│  └─ JsonCodec       │    │  └──────────┘ │  Clipboard    │  │
│                      │    │                └───────────────┘  │
│                      │    │  ┌──────────┐ ┌───────────────┐  │
│                      │    │  │  Config  │ │  ShellRC      │  │
│                      │    │  │  Manager │ │  Manager      │  │
│                      │    │  └──────────┘ └───────────────┘  │
│                      │    │  ┌──────────────────────────────┐ │
│                      │    │  │  FileStore (JSON r/w + flock)│ │
│                      │    │  └──────────────────────────────┘ │
└──────────────────────┘    └──────────────────────────────────┘
```

**与 v1 的关键差异：**

| v1 | v2 | 理由 |
|----|----|------|
| MessageBus 双向事件通道（28 事件变体） | 单向 `Channel<AppEvent>`（~10 变体），TUI→Core 直接调用 | 单主循环应用无需 pub/sub 总线 |
| LLM 和 Executor 同属"能力层" | LLM → 适配器层，PTY/Spawn → 基础设施层 | 外部服务网关 vs OS 进程管理，性质不同 |
| PTY 创建+监控循环混在 executor/pty.cj | infra/pty 只做创建/读写/销毁；core/pty_agent 做 agentic 循环 | 分离机制（FFI）与策略（LLM 决策） |
| PTY 循环：write/done 两种 action | PTY agentic 循环：LLM 选择 write/ask_user/wait/exit/interrupt | agentic tool-calling 更规范、可扩展 |
| SafetyAnalyzer 独立安全分析 | SafetyFallback 仅做 LLM 未标记时的兜底 | 避免与 LLM 判定冲突 |
| App.cj 编排层 | 取消，main.cj 直接初始化 | 减少无意义间接层 |
| core/types.cj 集中放所有类型 | 按功能域分文件：types/llm.cj, types/session.cj, types/pty.cj | 按领域内聚，避免单文件膨胀 |

### 1.2 设计原则

| 原则 | 说明 |
|------|------|
| **TUI 主线程不阻塞** | LLM 调用、命令执行在后台任务运行，通过 Channel 通知 TUI |
| **Screen 状态机驱动 UI** | 5 个 Screen，键盘事件直接分发，不经过中间事件层 |
| **适配器隔离外部服务** | LLM Provider 实现在 adapter/ 下，通过接口与 core 解耦 |
| **基础设施封装 OS 原语** | PTY 创建、子进程 spawn、剪贴板调用均在 infra/ 下，不含业务逻辑 |
| **Agentic PTY 循环** | 交互式命令执行采用 LLM tool-calling 循环，每轮选择工具执行 |
| **安全默认** | PTY 默认逐次确认，诊断命令默认需授权，危险命令二次确认 |
| **会话隔离** | 对话历史仅内存保留，进程退出即丢弃；仅环境上下文持久化 |

---

## 2. 包结构

```
termhelper/
├── cjpm.toml
├── src/
│   ├── main.cj                          # 入口：参数解析、配置加载、启动 TUI
│   │
│   ├── types/
│   │   ├── llm.cj                       # LLMResponse, CommandData, InvestigateData, SafetyLevel 等
│   │   ├── session.cj                   # Message, MessageRole, EnvironmentContext
│   │   └── pty.cj                       # PtyTool, PtyAction, PtyLoopState
│   │
│   ├── tui/
│   │   ├── tui.cj                       # TUI 初始化、主循环、Screen 路由、Channel 接收
│   │   ├── theme.cj                     # 颜色常量 (危险=橙色、成功=绿色等)
│   │   ├── input.cj                     # 键盘事件 → 应用动作转换
│   │   ├── screens/
│   │   │   ├── loading.cj               # 加载态：spinner + "正在思考..."
│   │   │   ├── result.cj                # 结果态：命令 + 分解说明 + 安全警告 + 选项菜单
│   │   │   ├── execute.cj               # 普通执行态：spawn 输出滚动展示
│   │   │   ├── pty_agentic.cj           # PTY agentic 态：PTY 输出 + LLM 决策 + 确认交互 + 模式切换
│   │   │   ├── prompt.cj                # 交互提示态：investigate 授权列表 / clarify 文本输入
│   │   │   └── error.cj                 # 错误态：错误信息 + 重试/退出
│   │   └── components/
│   │       ├── command_display.cj        # 命令展示 (含语法高亮占位)
│   │       ├── explanation.cj            # 命令分解说明
│   │       ├── safety_badge.cj           # 安全等级徽章
│   │       ├── option_menu.cj            # 选项菜单 (键盘导航)
│   │       ├── spinner.cj                # 加载动画
│   │       └── text_input.cj             # 文本输入组件
│   │
│   ├── core/
│   │   ├── session.cj                   # Session：对话历史管理、LLM 交互循环编排
│   │   ├── context.cj                   # ContextManager：环境上下文持久化 (加载/更新/存储)
│   │   ├── request.cj                   # RequestBuilder：构造 LLM 请求 (system prompt + context + history)
│   │   ├── pty_agent.cj                 # PtyAgentLoop：PTY agentic 循环 (见第 4 节)
│   │   └── safety_fallback.cj           # SafetyFallback：LLM 未标记危险时的本地兜底检查
│   │
│   ├── adapters/
│   │   ├── provider.cj                  # LLMProvider 抽象接口 (chat / chatStream)
│   │   ├── openai_compat.cj             # OpenAI 协议兼容实现
│   │   ├── anthropic.cj                 # Anthropic 协议实现
│   │   ├── google.cj                    # Google 协议实现
│   │   ├── sse.cj                       # SSE 协议解析器
│   │   └── codec.cj                     # LLM 响应 JSON 编解码
│   │
│   ├── infra/
│   │   ├── pty.cj                       # PTY 基础设施：posix_openpt/grantpt/unlockpt/fork/exec + master fd 读写
│   │   ├── spawn.cj                     # 普通子进程 spawn (stdout/stderr 捕获 + 超时)
│   │   ├── clipboard.cj                 # 剪贴板 (检测 Wayland/X11 → wl-copy/xclip)
│   │   ├── config.cj                    # 配置加载 (env → JSON → prompt)
│   │   ├── shell_rc.cj                  # Shell RC 管理 (install/uninstall alias/def)
│   │   └── fs.cj                        # 文件工具 (JSON 读写 + flock)
│   │
│   └── util/
│       └── prompt.cj                    # System prompt 模板常量
```

### 2.1 包依赖关系

```
main ──→ tui ──→ core ──→ adapters (LLM 接口)
  │        │       │
  │        │       └──→ infra (pty, spawn, clipboard, fs)
  │        │
  │        └──→ infra (config, shell_rc)  [TUI 需要配置和安装]
  │
  └──→ infra (config)  [main 需要加载配置]

types ←── 所有包 (无依赖，纯数据类型)
```

核心规则：
- `types/` 零依赖，被所有包引用
- `core/` 依赖 `adapters/` 的接口（不依赖具体实现）和 `infra/`
- `tui/` 依赖 `core/` 和 `infra/config`、`infra/shell_rc`
- `adapters/` 不依赖 `core/` 和 `tui/`
- `infra/` 不依赖 `core/`、`adapters/`、`tui/`

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

```cangjie
// LLM 响应的三种类型
enum LLMResponse {
    | Command(CommandData)
    | Investigate(InvestigateData)
    | Clarify(ClarifyData)
}

struct CommandData {
    command: String
    explanation: Explanation
    interactive: Bool            // 是否交互式命令
    safety: SafetyInfo
}

struct Explanation {
    summary: String              // 一句话概述
    breakdown: Array<BreakdownItem>
}

struct BreakdownItem {
    component: String            // 命令组件 (如 "rm", "-rf")
    explanation: String          // 组件说明
}

struct SafetyInfo {
    level: SafetyLevel           // safe / caution / danger / privilege
    warnings: Array<String>
}

enum SafetyLevel {
    | Safe
    | Caution
    | Danger
    | Privilege
}

struct InvestigateData {
    reason: String               // 调查理由
    commands: Array<DiagnosticCommand>
}

struct DiagnosticCommand {
    command: String
    rationale: String
    authorized: Bool = false     // 运行时字段，非 LLM 输出
}

struct ClarifyData {
    question: String
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
    | Tool                     // 诊断命令结果
}

struct EnvironmentContext {
    os: Option<String>
    distro: Option<String>
    packageManager: Option<String>
    shell: String              // 从 SHELL 环境变量获取
    tools: HashMap<String, String>
    extras: HashMap<String, String>
    lastUpdated: Int64
}
```

### 3.3 PTY Agentic 工具集 (types/pty.cj)

```cangjie
// LLM 在 PTY agentic 循环中可选择的工具
enum PtyTool {
    | Write(String, String)      // 写入内容 + 理由
    | AskUser(String)            // 需要用户提供信息 (问题描述)
    | Wait                       // 等待更多输出
    | Exit(String)               // 命令已完成 (摘要)
    | Interrupt(String)          // 检测到异常，建议中断 (原因)
}

// PTY agentic 循环状态
enum PtyLoopState {
    | WaitingOutput              // 等待 PTY 新输出
    | LLMDecision                // LLM 正在决策
    | AwaitingConfirm(String, String)  // 等待用户确认 (待写入内容, 理由)
    | AwaitingUserInput(String)  // 等待用户输入 (LLM 的问题)
    | Finished(CommandResult)    // 已完成
    | Interrupted(String)        // 已中断
}
```

### 3.4 AppEvent — 后台任务 → TUI 通知

```cangjie
// 单向通道：后台任务 → TUI 主循环
// 约 10 个变体，vs v1 的 28 个
enum AppEvent {
    | LLMChunk(String)             // 流式响应片段 (TUI 实时更新)
    | LLMDone(LLMResponse)         // 完整响应已解析
    | LLMError(String)             // API 错误
    | SpawnOutput(String)          // spawn 输出行
    | SpawnDone(CommandResult)     // spawn 执行完毕
    | PtyOutput(String)            // PTY 新输出 (渲染后的虚拟屏幕 diff 文本)
    | PtyStateChange(PtyLoopState) // PTY agentic 循环状态变更
    | ClipboardDone                // 复制完成
    | ContextSaved                 // 上下文已持久化
}

struct CommandResult {
    exitCode: Int32
    stdout: String
    stderr: String
}
```

---

## 4. PTY Agentic 循环（核心设计变更）

### 4.1 设计动机

v1 的 PTY 循环中 LLM 只返回 `{action: "write"}` 或 `{action: "done"}`，扩展性差。实际场景中 LLM 需要更多决策空间：

- 密码提示出现，但 LLM 不知道密码 → 需要 **ask_user**
- 输出不完整（进度条刷了一半）→ 需要 **wait** 等待更多输出
- 检测到异常（"Permission denied"）→ 需要 **interrupt** 建议终止
- 程序正常结束 → **exit** 给出摘要

agentic tool-calling 循环：每轮将 PTY 新输出 + 可用工具定义发送给 LLM，LLM 必须选择一种工具，系统执行工具后进入下一轮。

### 4.2 循环流程

```
PtyAgentLoop.start(command)
  │
  ├── infra/pty.cj: 创建 PTY，spawn 子进程
  │
  ▼
┌─────────────────────────────────────────────┐
│  agentic 循环 (core/pty_agent.cj)           │
│                                             │
│  while true:                                │
│    ┌──────────────────────────────────┐     │
│    │ 1. 读 PTY master fd (非阻塞)      │     │
│    │    → 追加到原始输出缓冲区          │     │
│    │    → 更新虚拟终端屏幕状态          │     │
│    │    → 计算渲染 diff (新增文本)      │     │
│    └──────────────┬───────────────────┘     │
│                   │                         │
│    ┌──────────────▼───────────────────┐     │
│    │ 2. 如果子进程已退出:              │     │
│    │    → PtyTool.Exit(摘要)          │     │
│    │    → break                       │     │
│    └──────────────┬───────────────────┘     │
│                   │                         │
│    ┌──────────────▼───────────────────┐     │
│    │ 3. 构造 LLM 请求:                │     │
│    │    system: PTY agent prompt      │     │
│    │    context: 命令 + 历史决策       │     │
│    │    user: "以下是 PTY 最新输出:"   │     │
│    │          + diff 文本             │     │
│    │    tools: [write,ask,wait,       │     │
│    │            exit,interrupt]       │     │
│    └──────────────┬───────────────────┘     │
│                   │                         │
│    ┌──────────────▼───────────────────┐     │
│    │ 4. LLM 返回 PtyTool 选择         │     │
│    └──────────────┬───────────────────┘     │
│                   │                         │
│        ┌──────────┼──────────┬──────────┬──────────┐
│        ▼          ▼          ▼          ▼          ▼
│      Write     AskUser     Wait      Exit    Interrupt
│        │          │          │          │          │
│  ┌─────▼────┐ ┌──▼───┐  ┌──▼──┐  ┌───▼───┐  ┌──▼────┐
│  │默认模式:  │ │展示  │  │sleep│  │展示   │  │展示   │
│  │等待用户  │ │问题  │  │选择的│  │摘要   │  │原因   │
│  │确认后    │ │等待  │  │秒数后│  │结束   │  │询问   │
│  │写入PTY  │ │输入  │  │继续 │  │循环   │  │是否   │
│  │          │ │传给  │  │循环 │  │       │  │中断   │
│  │全自动:   │ │LLM   │  │     │  │       │  │       │
│  │直接写入  │ │      │  │     │  │       │  │       │
│  └─────────┘ └──────┘  └─────┘  └───────┘  └───────┘
│                   │
│            继续下一轮循环
└─────────────────────────────────────────────┘
```

### 4.3 PTY 输出捕获策略

采用**虚拟终端缓冲区 + diff** 方案，兼容自绘 TUI（如 apt 进度条、htop）：

```
原始 PTY 输出流 (含 ANSI 转义序列)
         │
         ▼
┌─────────────────────┐
│ 虚拟终端屏幕缓冲区    │  ← 解析 ANSI 序列，维护 W×H 字符网格
│ (W×H 单元格)        │
└─────────┬───────────┘
          │ 每次有新输出后
          ▼
┌─────────────────────┐
│ 屏幕 diff            │  ← 比较前后两帧，提取变化的文本行
│ (仅新增/变化的行)     │
└─────────┬───────────┘
          │
          ▼
   发送给 LLM 的上下文
```

- 自绘 TUI 兼容性：`htop`、`vim` 等通过 ANSI 序列重绘屏幕，虚拟终端缓冲区忠实地反映屏幕状态变化，diff 只捕获实际变化的区域
- v1 范围可降级为简化版：维护一个行缓冲，取最近 N 行；虚拟终端解析器预留接口后续替换
- diff 频率自适应：无新输出时等待，有新输出时立即捕获；连续输出时批量发送（避免每字节触发 LLM 调用）

### 4.4 LLM PTY Agent System Prompt 要点

```
你是一个终端操作代理。你将收到 PTY 的输出，需要选择工具来响应当前状态。

可用工具：
- write(content, reason): 向终端写入内容。默认会请求用户确认。
- ask_user(question): 需要用户提供信息（如密码）。
- wait: 输出不完整，等待更多内容。
- exit(summary): 命令执行完成。
- interrupt(reason): 检测到异常，建议中断。

规则：
- 看到 password/passphrase 提示时，优先使用 ask_user 而非猜测密码
- 看到 [Y/n] 确认提示时，使用 write("Y\n", ...) 或 write("n\n", ...)
- 检测到 "Permission denied"、"command not found" 等错误时，使用 interrupt
- 不确定是否完成时，使用 wait
```

---

## 5. 关键流程

### 5.1 主交互流程

```
用户输入: ?? 删除所有std开头的文件夹
                  │
┌─────────────────▼────────────────────────────────────┐
│ main.cj                                              │
│  1. 解析命令行参数: query = "删除所有std开头的文件夹"    │
│  2. config.load() — 加载配置                          │
│  3. context.load() — 加载环境上下文                    │
│  4. 创建 Session(llmClient, envContext)               │
│  5. session.append(User, query)                      │
│  6. 创建 Channel<AppEvent>                           │
│  7. 后台 spawn: llmClient.chatStream(→ channel)       │
│  8. TUI.init() → 进入主循环                           │
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
│        update loading animation text                 │
│      Some(AppEvent.LLMDone(response)) →              │
│        screen = dispatch(response)                   │
│      Some(AppEvent.LLMError(err)) →                  │
│        screen = Screen::Error(err)                   │
│      Some(AppEvent.SpawnOutput(line)) →              │
│        execute_screen.append(line)                   │
│      Some(AppEvent.SpawnDone(result)) →              │
│        execute_screen.show_result(result)            │
│      Some(AppEvent.PtyOutput(text)) →                │
│        pty_screen.append_output(text)                │
│      Some(AppEvent.PtyStateChange(state)) →          │
│        pty_screen.update_state(state)                │
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
  ├── System Prompt (util/prompt.cj + JSON Schema)
  ├── EnvironmentContext (JSON 序列化)
  └── Messages[] (对话历史)
        │
        ▼
LLMProvider.chatStream(request, onChunk)  [adapters/provider.cj]
  ├── HTTP POST (stream: true)
  ├── SseParser 逐块解析 resp.body        [adapters/sse.cj]
  └── onChunk → channel.send(AppEvent.LLMChunk(...))
        │
        ▼
  流结束 → Codec.parse(完整响应)           [adapters/codec.cj]
         → channel.send(AppEvent.LLMDone(response))
```

### 5.3 环境调查流程

```
LLM 返回 type: "investigate"
  │
  ▼
TUI 切换到 Prompt 屏 (investigate 子模式)
  ├── 展示调查理由 (reason)
  ├── 展示诊断命令列表 (每条附 rationale)
  └── 用户逐条/批量授权
        │
        ▼
  infra/spawn.cj 执行授权命令 (每命令 5s 超时)
        │
        ▼
  结果 → session.append(Tool, result)
  context.update(newInfo)
  发起新一轮 LLM 调用 → 回到 Loading
```

### 5.4 普通执行流程

```
用户选择 "运行" (interactive: false)
  │
  ▼
TUI 切换到 Execute 屏
  ├── infra/spawn.cj: spawn 子进程 (后台)
  ├── stdout/stderr 逐行 → channel.send(AppEvent.SpawnOutput(...))
  └── 进程退出 → channel.send(AppEvent.SpawnDone(result))
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
    | Loading                     // spinner + 流式文本
    | Result(CommandData)         // 命令 + 说明 + 安全警告 + 选项菜单
    | Execute(ExecuteState)       // 普通 spawn 执行，实时输出
    | PtyAgentic(PtyLoopState)    // PTY agentic 循环，交互式
    | Prompt(PromptMode)          // investigate 或 clarify
    | Error(String, Bool)         // 错误信息 + 是否可重试
}

enum PromptMode {
    | Investigate(InvestigateData)
    | Clarify(ClarifyData)
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
              │  └──┬─┬─┘│(invest/  │                   │
              │     │ │  │ clarify) │                   │
              │     │ │  └────┬─────┘                   │
              │     │ │       │                         │
              │     │ │  用户授权/回答                    │
              │     │ │       │                         │
              │     │ │       └──→ 新一轮 LLM 调用 ───────┘
              │     │ │
              │     │ └── 修改 → 新一轮 LLM 调用 ────────┘
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

5 个 Screen，vs v1 的 7 个（去掉了独立的 Investigate、Clarify、Executing、PtyMonitor，合并为 Prompt 和 Execute/PtyAgentic）。

---

## 7. 并发模型

### 7.1 线程/任务模型

```
┌──────────────────────────────────────────────────────┐
│  Main Thread (TUI)                                   │
│  - ratatui poll_event + draw 循环                     │
│  - 键盘输入 → 直接调用 screen.handle_input()          │
│  - Channel.tryRecv() 非阻塞接收后台事件                │
│  - 严禁阻塞 I/O                                       │
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
│ - JSON 解析      │         │ - PTY agentic 循环     │
│ → channel.send() │         │ → channel.send()      │
└──────────────────┘         └───────────────────────┘
```

**关键简化：** TUI 到 Core 的通信不再经过 Channel，而是直接函数调用。后台任务到 TUI 的通信走单一 `Channel<AppEvent>`，TUI 主循环每帧非阻塞 tryRecv。

### 7.2 上下文文件并发安全

```
ContextManager (core/context.cj) → infra/fs.cj
  ├── 读 context.json: flock LOCK_SH (共享锁)
  └── 写 context.json: flock LOCK_EX (排他锁)
```

---

## 8. 配置与安装

### 8.1 配置优先级

```
API Key 读取顺序:
  1. 环境变量 (LLM_API_KEY / OPENAI_API_KEY / ANTHROPIC_API_KEY / GOOGLE_API_KEY)
  2. ~/.config/termhelper/config.json → api_key 字段
  3. TUI 首次运行交互式提示输入 (写入 config.json)

LLM Provider 选择:
  1. config.json → provider 字段 (openai_compat / anthropic / google)
  2. 默认 openai_compat
```

### 8.2 config.json

```jsonc
{
  "version": 1,
  "provider": "openai_compat",
  "llm": {
    "api_key": "",
    "base_url": "https://api.openai.com/v1",
    "model": "gpt-4o"
  },
  "execution": {
    "spawn_timeout_sec": 300,
    "pty_default_mode": "confirm"
  }
}
```

### 8.3 安装/卸载

```
termhelper install
  1. 检测 Shell (SHELL 环境变量)
  2. 追加 alias/def 到对应 RC 文件
  3. 创建 ~/.config/termhelper/ (0700)
  4. 提示 source RC 或重启 Shell

termhelper uninstall
  1. 从 RC 文件移除 termhelper 写入的行
  2. 询问是否删除 ~/.config/termhelper/
```

---

## 9. 错误处理

| 场景 | 处理 |
|------|------|
| LLM API 不可达 | Error 屏："无法连接到 LLM 服务" — 重试/退出 |
| LLM 返回非 JSON | Error 屏：展示原始响应 + "格式异常" — 重试/退出 |
| JSON 解析失败 | Error 屏：展示解析错误详情 — 重试/退出 |
| 诊断命令执行失败 | stderr 作为 Tool 消息返回给 LLM，LLM 自行决策替代方案 |
| 用户命令执行失败 | Execute 屏展示退出码 + stderr，可返回 Result 屏修改 |
| PTY 创建失败 | 降级为"仅复制" + 提示 |
| 剪贴板工具缺失 | 展示命令文本 + 提示安装 |
| 配置文件损坏 | 默认配置 + 警告 |
| 上下文文件损坏 | 丢弃，重新调查 |
| 命令执行超时 | 展示部分输出 + 继续等待/中断选项 |

**原则：任何错误不崩溃退出 TUI，始终给用户可操作的回退路径。**

---

## 10. 安全边界

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
│                                               │
│  系统保证:                                     │
│  - API Key 存储在环境变量或 0600 配置文件        │
│  - context.json 不存储敏感信息                  │
│  - 对话历史不持久化 (仅内存)                    │
│  - 全自动模式可随时切回默认模式或中断            │
│  - SafetyFallback 仅在 LLM 未标记时兜底         │
└───────────────────────────────────────────────┘
```

---

## 11. 待实现阶段验证

| 项 | 说明 | 影响范围 |
|----|------|----------|
| ratatui binding 能力验证 | 全屏接管、键盘事件、颜色渲染 | tui/ 全部 |
| nushell def 参数展开语法 | `...$args` 兼容性 | infra/shell_rc.cj |
| Cangjie FFI + libc | posix_openpt/fork/exec 的 FFI 声明 | infra/pty.cj |
| `stdx.net.http` 流式读取 | HTTPS + 长连接行为 | adapters/sse.cj |
| 仓颉并发原语 | Channel / spawn 的实际 API | core/session.cj, main.cj |
| 虚拟终端 ANSI 解析器 | 是否纳入 v1 还是降级为行缓冲 | core/pty_agent.cj |
| JSON Schema version 字段 | 前向兼容需要 | adapters/codec.cj |
