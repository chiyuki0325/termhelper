# 智能终端助手 架构设计 v1

> 基于 [需求分析说明书 v5](./requirements-final.md) 和 [技术选型](./tech-selection.md)

## 1. 架构总览

### 1.1 分层架构

```
┌──────────────────────────────────────────────────────────────┐
│                        入口层 (main)                           │
│  命令行参数解析 → 配置初始化 → 启动 App                        │
└──────────────────────────┬───────────────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────────────┐
│                        TUI 层 (tui/)                           │
│  ┌──────────┐  ┌─────────────┐  ┌──────────────────────────┐ │
│  │  Screen  │  │  Components  │  │  Theme / Keybindings     │ │
│  │  Router  │  │  (可复用组件) │  │  (颜色/键盘绑定)         │ │
│  └──────────┘  └─────────────┘  └──────────────────────────┘ │
│                                                                 │
│  Screen 状态机: Loading → Investigate/Clarify/Result →        │
│                 Executing/PtyMonitor → Result → Exit           │
└──────────────────────────┬───────────────────────────────────┘
                           │ 事件/命令
┌──────────────────────────▼───────────────────────────────────┐
│                       核心层 (core/)                           │
│  ┌────────────┐  ┌────────────┐  ┌─────────────────────────┐ │
│  │  Session   │  │  Context   │  │  SafetyAnalyzer         │ │
│  │  (会话编排) │  │  Manager   │  │  (安全规则引擎)          │ │
│  └─────┬──────┘  └─────┬──────┘  └────────────┬────────────┘ │
│        │               │                      │               │
│  ┌─────┴───────────────┴──────────────────────┴────────────┐ │
│  │              MessageBus (内部事件通道)                    │ │
│  │   TUI Event ←→ Core ←→ LLM / Executor / Clipboard       │ │
│  └──────────────────────────────────────────────────────────┘ │
└──────────────────────────┬───────────────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────────────┐
│                      能力层 (llm/ + executor/)                 │
│  ┌────────────────────┐  ┌──────────────────────────────────┐ │
│  │  LLM Client        │  │  Command Executor                │ │
│  │  (抽象接口)         │  │  ┌──────────┐ ┌──────────────┐  │ │
│  │  ├─ OpenAICompat   │  │  │  Spawn   │ │  PtyManager  │  │ │
│  │  ├─ Anthropic      │  │  │  (子进程) │ │  (PTY 接管)  │  │ │
│  │  └─ Google         │  │  └──────────┘ └──────────────┘  │ │
│  │  ├─ SseParser      │  │  ┌──────────────────────────┐   │ │
│  │  └─ JsonCodec      │  │  │  Clipboard               │   │ │
│  └────────────────────┘  │  │  (wl-copy / xclip)       │   │ │
│                          │  └──────────────────────────┘   │ │
│                          └──────────────────────────────────┘ │
└──────────────────────────┬───────────────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────────────┐
│                      基础设施层                                │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────────┐ │
│  │  Config  │  │  Install │  │  File IO │  │  Shell RC    │ │
│  │  Manager │  │  /Uninst │  │  + flock │  │  Manager     │ │
│  └──────────┘  └──────────┘  └──────────┘  └──────────────┘ │
└──────────────────────────────────────────────────────────────┘
```

### 1.2 设计原则

| 原则 | 说明 |
|------|------|
| **TUI 主线程不阻塞** | LLM 调用、命令执行等长时操作放入后台任务，通过事件通道与 TUI 通信 |
| **状态机驱动 UI** | TUI 展示由有限状态机驱动，每个 Screen 对应一个状态，转换由事件触发 |
| **接口隔离** | LLM 客户端、命令执行器均通过抽象接口访问，具体实现可替换 |
| **安全默认** | PTY 接管默认逐次确认，诊断命令默认需授权，危险命令默认二次确认 |
| **会话隔离** | 对话历史仅存在于内存中（一个 Session 对象），进程退出即丢弃；仅环境上下文持久化 |

---

## 2. 包结构

```
termhelper/
├── cjpm.toml                          # 仓颉包清单
├── src/
│   ├── main.cj                        # 入口：参数解析、配置加载、启动 App
│   │
│   ├── app/
│   │   └── app.cj                     # App 编排器：持有 Session/TUI/Config，协调生命周期
│   │
│   ├── tui/
│   │   ├── tui.cj                     # TUI 初始化、主循环、Screen 路由
│   │   ├── event.cj                   # TUI 事件定义 (键盘/自定义事件)
│   │   ├── theme.cj                   # 颜色常量 (危险=橙色、成功=绿色等)
│   │   ├── screens/
│   │   │   ├── loading.cj             # 加载态：spinner + "AI 正在思考..."
│   │   │   ├── result.cj              # 结果态：命令 + 说明 + 安全警告 + 选项菜单
│   │   │   ├── investigate.cj         # 调查态：诊断命令列表 + 授权交互
│   │   │   ├── clarify.cj             # 澄清态：LLM 提问 + 用户输入区
│   │   │   ├── executing.cj           # 执行态：spawn 输出实时滚动
│   │   │   ├── pty_monitor.cj         # PTY 接管态：PTY 输出 + 确认提示 + 模式切换
│   │   │   └── error.cj               # 错误态：错误信息 + 重试/退出
│   │   └── components/
│   │       ├── command_display.cj      # 命令展示组件 (语法高亮占位)
│   │       ├── explanation.cj          # 命令分解说明组件
│   │       ├── safety_badge.cj         # 安全等级徽章 (安全/注意/危险/提权)
│   │       ├── option_menu.cj          # 选项菜单组件 (键盘导航)
│   │       ├── spinner.cj              # 加载动画
│   │       └── text_input.cj           # 单行/多行文本输入组件
│   │
│   ├── core/
│   │   ├── session.cj                 # Session：会话编排、对话历史管理、LLM 交互循环
│   │   ├── context.cj                 # ContextManager：环境上下文持久化加载/更新/存储
│   │   ├── safety.cj                  # SafetyAnalyzer：本地补充规则匹配 (rm -rf, mkfs, dd...)
│   │   ├── message_bus.cj             # 内部事件通道 (TUI ↔ Core ↔ 能力层)
│   │   └── types.cj                   # 核心数据类型 (Screen, Command, SafetyLevel, ...)
│   │
│   ├── llm/
│   │   ├── provider.cj                # LLM 抽象接口 (chat / chatStream)
│   │   ├── openai_compat.cj           # OpenAI 协议兼容实现 (OpenAI/DeepSeek/Moonshot/...)
│   │   ├── anthropic.cj               # Anthropic 协议实现
│   │   ├── google.cj                  # Google 协议实现
│   │   ├── sse.cj                     # SSE 协议解析器 (data:/event:/id: 行解析)
│   │   ├── codec.cj                   # LLM 响应 JSON 解析 → LLMResponse 枚举
│   │   └── prompt.cj                  # System prompt 模板构造
│   │
│   ├── executor/
│   │   ├── spawn.cj                   # 普通子进程 spawn (stdout/stderr 捕获 + 超时控制)
│   │   ├── pty.cj                     # PTY 管理 (FFI: posix_openpt/grantpt/unlockpt/fork/exec)
│   │   └── clipboard.cj               # 剪贴板 (检测 Wayland/X11 → spawn wl-copy/xclip)
│   │
│   ├── config/
│   │   ├── config.cj                  # 配置加载 (env → JSON → prompt)
│   │   └── shell_rc.cj                # Shell RC 文件管理 (install/uninstall alias/def)
│   │
│   └── util/
│       └── fs.cj                      # 文件工具 (JSON 读写 + flock 锁)
```

### 2.1 cjpm.toml 依赖

```toml
[package]
name = "termhelper"
version = "0.1.0"
language = "cangjie"
cj-version = "1.1.0"

[dependencies]
# ratatui binding — TUI 框架
ratatui = { git = "https://gitcode.com/Cangjie-SIG/ratatui" }
# stdx 扩展标准库 (http, json, log 等) — 随工具链提供
```

---

## 3. 核心数据模型

### 3.1 LLM 交互类型

```cangjie
// LLM 结构化响应的三种类型
enum LLMResponse {
    | Command(CommandData)
    | Investigate(InvestigateData)
    | Clarify(ClarifyData)
}

struct CommandData {
    command: String              // 可执行命令字符串
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
    command: String              // 诊断命令
    rationale: String            // 执行理由
    authorized: Bool = false     // 用户是否已授权 (非 LLM 字段，运行时设置)
}

struct ClarifyData {
    question: String             // 向用户澄清的问题
}
```

### 3.2 TUI 状态机

```
                    ┌──────────┐
                    │  START   │
                    └────┬─────┘
                         │ 用户输入 ??查询
                         ▼
                   ┌──────────┐
              ┌───→│ LOADING  │←──────────────────────────┐
              │    └────┬─────┘                           │
              │         │ LLM 响应到达                     │
              │         ▼                                 │
              │  ╔══════════════════╗                     │
              │  ║  type 分发       ║                     │
              │  ╚═══╤══════╤══════╝                     │
              │      │      │                            │
         command  investigate  clarify                    │
              │      │      │                            │
              ▼      ▼      ▼                            │
    ┌──────────┐ ┌──────────┐ ┌──────────┐              │
    │  RESULT  │ │INVESTIGATE│ │ CLARIFY  │              │
    └──┬───┬──┘ └────┬─────┘ └────┬─────┘              │
       │   │         │            │                      │
       │   │    授权/拒绝     用户回答                    │
       │   │         │            │                      │
       │   │         └────────────┘                      │
       │   │              │                              │
       │   │         新一轮 LLM 调用 ─────────────────────┘
       │   │
       │   └── 修改 ──→ 新一轮 LLM 调用 ─────────────────┘
       │
       ├── 运行 ──→ ┌───────────┐
       │            │ EXECUTING │ ──→ 完成/中断 ──→ RESULT
       │            └───────────┘
       │
       ├── 运行并接管 ──→ ┌─────────────┐
       │                  │ PTY_MONITOR │ ──→ 完成/中断 ──→ RESULT
       │                  └─────────────┘
       │
       └── 复制 ──→ ┌──────┐
                    │ EXIT │
                    └──────┘
```

### 3.3 Session 模型

```cangjie
class Session {
    // 对话历史 (内存，会话结束即丢弃)
    var messages: ArrayList<Message>
    // 环境上下文 (跨会话持久化)
    var envContext: EnvironmentContext
    // LLM 客户端 (抽象接口)
    let llmClient: LLMProvider
    // 当前交互轮次
    var turn: Int64 = 0

    // 构造 LLM 请求 (system prompt + context + history + 最新查询)
    func buildRequest(): LLMRequest
    // 追加消息到历史
    func append(msg: Message): Unit
    // 更新环境上下文
    func updateContext(newCtx: EnvironmentContext): Unit
}

struct Message {
    role: MessageRole       // System / User / Assistant / Tool
    content: String
    timestamp: Int64
}

enum MessageRole {
    | System
    | User
    | Assistant
    | Tool                   // 诊断命令结果
}

struct EnvironmentContext {
    os: Option<String>
    distro: Option<String>
    packageManager: Option<String>
    shell: String            // 从 SHELL 环境变量获取，始终有值
    tools: HashMap<String, String>  // 工具名 → 版本
    extras: HashMap<String, String> // LLM 认为有价值的其他信息
    lastUpdated: Int64
}
```

### 3.4 事件系统

```cangjie
// TUI → Core 事件 (用户操作)
enum UIEvent {
    | RunCommand                 // 运行 (非交互式)
    | RunAndTakeover             // 运行并接管 (交互式)
    | CopyToClipboard            // 复制
    | Modify(String)             // 修改，带修改指示
    | AuthorizeDiagnostic(Array<Int64>)  // 授权指定索引的诊断命令
    | RejectDiagnostic           // 拒绝所有诊断命令
    | ClarifyAnswer(String)      // 澄清回答
    | ToggleAutoMode             // PTY 模式切换
    | ConfirmPtyWrite            // PTY 确认写入
    | RejectPtyWrite             // PTY 拒绝写入
    | Interrupt                  // 中断当前操作
    | Retry                      // 重试 (错误态)
    | Quit                       // 退出
}

// Core → TUI 事件 (状态更新)
enum CoreEvent {
    | LoadingStarted
    | LLMResponseParsed(LLMResponse)    // 收到 LLM 响应
    | DiagnosticResult(Array<String>)   // 诊断命令执行结果
    | CommandFinished(CommandResult)    // spawn 执行完毕
    | PtyOutput(String)                 // PTY 有新输出
    | PtyFinished(CommandResult)        // PTY 命令完成
    | PtyLLMAction(String, String)      // LLM 计划写入的内容 + 理由
    | ClipboardDone                    // 复制完成
    | Error(String)                    // 错误
    | ContextUpdated                    // 环境上下文已更新
}
```

---

## 4. 关键流程

### 4.1 主交互流程

```
用户输入: ?? 删除所有std开头的文件夹
                  │
┌─────────────────▼────────────────────────────────────┐
│ main.cj                                              │
│  1. 解析命令行参数: query = "删除所有std开头的文件夹"     │
│  2. Config.load() — 加载配置                         │
│  3. ContextManager.load() — 加载环境上下文             │
│  4. App.run(query, config, context)                  │
└─────────────────┬────────────────────────────────────┘
                  │
┌─────────────────▼────────────────────────────────────┐
│ App.run()                                            │
│  1. 创建 Session (llmClient, envContext)              │
│  2. 创建 TUI 实例                                     │
│  3. session.append(User, query)                      │
│  4. 提交后台任务: llmClient.chat(session.buildRequest())│
│  5. TUI 进入 Loading 屏，启动主循环                     │
└─────────────────┬────────────────────────────────────┘
                  │
┌─────────────────▼────────────────────────────────────┐
│ TUI 主循环 (tui.cj)                                  │
│  while screen != Exit:                              │
│    1. 检查 CoreEvent 通道 (非阻塞)                     │
│       - 有事件 → 更新 screen 状态                     │
│    2. 检查 UIEvent 通道 (非阻塞)                       │
│       - 有事件 → 转发给 Session 处理                   │
│    3. 绘制当前 Screen                                │
│    4. 读取键盘输入 → 转换为 UIEvent                   │
└─────────────────────────────────────────────────────┘
```

### 4.2 LLM 调用流程 (含流式渲染)

```
Session.buildRequest()
  │
  ├── System Prompt (固定模板: 角色定义 + JSON Schema 约束)
  ├── Environment Context (JSON 序列化)
  └── Messages[] (对话历史 + 当前查询)
        │
        ▼
LLMProvider.chatStream(request, onChunk)
  │
  ├── HTTP POST (stream: true)
  ├── SseParser 逐块解析 resp.body (InputStream.read)
  │     data: {"type":"command","data":{...}}
  │     data: [DONE]
  │
  └── onChunk(chunk: String)
        │
        ▼
  Codec.parse(chunk) → LLMResponse
        │
        ▼
  发送 CoreEvent::LLMResponseParsed → TUI 切换 Screen
```

### 4.3 PTY 接管循环

```
用户选择 "运行并接管"
  │
  ▼
PtyManager.spawn(command)
  │
  ├── posix_openpt(O_RDWR | O_NOCTTY)
  ├── grantpt(master) / unlockpt(master)
  ├── fork():
  │     ├── Child: setsid() → open(slave) → dup2 stdin/stdout/stderr → exec(command)
  │     └── Parent: 返回 master fd
  │
  ▼
PtyMonitor 循环 (后台任务):
  │
  while master_alive:
  │
  ├── 非阻塞读 master fd (select/epoll)
  │     │
  │     └── 有数据 → 发送 CoreEvent::PtyOutput(text)
  │                  │
  │                  ▼
  │            TUI 渲染 PTY 输出
  │            发送给 LLM: "以下是 PTY 的最新输出: {text}，请决策下一步操作"
  │                  │
  │                  ▼
  │            LLM 返回: {action: "write", content: "Y\n", reason: "确认升级"}
  │            或:       {action: "done", summary: "命令已完成"}
  │                  │
  │                  ▼
  │            发送 CoreEvent::PtyLLMAction(content, reason)
  │                  │
  │                  ▼
  │            ┌─ 默认模式: TUI 展示 "LLM 将写入 '{content}'，原因: {reason}"
  │            │            等待用户 ConfirmPtyWrite / RejectPtyWrite
  │            │            Confirm → write(master, content)
  │            │
  │            └─ 全自动模式: 直接 write(master, content)
  │
  └── 子进程退出 → PtyFinished(exitCode, output)
```

### 4.4 环境调查流程

```
LLM 返回 type: "investigate"
  │
  ▼
TUI 切换到 Investigate 屏
  │
  ├── 展示调查理由 (reason)
  ├── 展示诊断命令列表 (每条附 rationale)
  └── 等待用户操作:
        │
        ├── 逐条授权: 高亮选中 → 空格勾选 → Enter 执行
        └── 批量授权: 全选 → Enter 执行
              │
              ▼
        Spawn 执行被授权的诊断命令 (5s 超时)
              │
              ▼
        结果追加到 session.messages (role: Tool)
        调用 ContextManager.update() 更新环境上下文
              │
              ▼
        发起新一轮 LLM 调用 (回到 Loading 屏)
```

---

## 5. 并发模型

### 5.1 线程/任务模型

```
┌──────────────────────────────────────────────────────┐
│  Main Thread (TUI)                                   │
│  - ratatui 渲染循环                                   │
│  - 键盘输入处理                                       │
│  - 事件分发 (非阻塞 poll)                              │
│  - 不得执行任何阻塞 I/O                                │
└──────────┬───────────────────────────────────────────┘
           │ 通过 MessageBus (channel) 通信
           │
    ┌──────┴──────────────────────────────┐
    │                                      │
┌───▼──────────────┐         ┌────────────▼──────────┐
│ LLM Task         │         │ Executor Task         │
│ (后台 spawn)      │         │ (后台 spawn)           │
│                  │         │                       │
│ - HTTP 请求      │         │ - spawn 子进程         │
│ - SSE 解析       │         │ - PTY 读写             │
│ → CoreEvent     │         │ → CoreEvent            │
└──────────────────┘         └───────────────────────┘
```

### 5.2 MessageBus 设计

使用仓颉标准库的并发通道 (`std.concurrent.Channel`) 实现：

```cangjie
class MessageBus {
    // TUI → Core 方向
    let uiEventSender: Sender<UIEvent>
    let uiEventReceiver: Receiver<UIEvent>
    // Core → TUI 方向
    let coreEventSender: Sender<CoreEvent>
    let coreEventReceiver: Receiver<CoreEvent>

    // 发送 UI 事件 (TUI 线程调用)
    func sendUIEvent(event: UIEvent): Unit { uiEventSender.send(event) }
    // 接收 UI 事件 (Core 使用)
    func recvUIEvent(): Option<UIEvent> { uiEventReceiver.tryRecv() }
    // 发送核心事件 (后台任务调用)
    func sendCoreEvent(event: CoreEvent): Unit { coreEventSender.send(event) }
    // 接收核心事件 (TUI 线程调用，非阻塞)
    func recvCoreEvent(): Option<CoreEvent> { coreEventReceiver.tryRecv() }
}
```

### 5.3 上下文文件并发安全

```
ContextManager
  │
  ├── 读 context.json: 获取共享锁 (flock LOCK_SH)
  │     - 多实例可同时读
  │
  └── 写 context.json: 获取排他锁 (flock LOCK_EX)
        - 阻塞直到所有读锁释放
        - 写入完成后释放
```

---

## 6. 配置与安装

### 6.1 配置优先级

```
API Key 读取顺序:
  1. 环境变量 (LLM_API_KEY / OPENAI_API_KEY / ANTHROPIC_API_KEY / GOOGLE_API_KEY)
  2. ~/.config/termhelper/config.json 中的 api_key 字段
  3. TUI 首次运行时交互式提示输入 (写入 config.json)

LLM Provider 选择:
  1. config.json 中的 provider 字段 (openai_compat / anthropic / google)
  2. 默认 openai_compat (最通用)
```

### 6.2 config.json 结构

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
    "pty_default_mode": "confirm"  // confirm | auto
  }
}
```

### 6.3 安装/卸载流程

```
安装: termhelper install
  1. 检测当前 Shell (SHELL 环境变量)
  2. 在对应的 RC 文件中追加 alias/def 行
     - bash/zsh: alias '??'='termhelper'
     - fish: alias '??' termhelper
     - nushell: def "??" [ ...args ] { termhelper ...$args }
  3. 创建 ~/.config/termhelper/ 目录 (0700)
  4. 提示用户 source RC 文件或重启 Shell

卸载: termhelper uninstall
  1. 从 RC 文件中移除 termhelper 写入的行片段
  2. 询问是否删除 ~/.config/termhelper/
```

---

## 7. 错误处理策略

| 场景 | 处理方式 |
|------|----------|
| LLM API 不可达 | TUI 展示 Error 屏："无法连接到 LLM 服务，请检查网络和 API Key" — 提供重试/退出 |
| LLM 返回非 JSON | 展示原始响应 + "模型返回格式异常，请重试" — 提供重试/修改 prompt/退出 |
| JSON 解析失败 (字段缺失/类型不符) | 同上，展示解析错误详情 |
| 诊断命令执行失败 | 将 stderr 作为结果返回给 LLM，由 LLM 决定替代方案 |
| 用户命令执行失败 | 展示退出码 + stderr，回到 Result 屏 (可修改重试) |
| PTY 创建失败 | 降级为"仅复制"模式 + 提示 |
| 剪贴板工具未安装 | 展示命令文本 + 提示安装 wl-clipboard 或 xclip |
| 配置文件损坏 | 使用默认配置 + 警告，TUI 内提供重置选项 |
| 上下文文件损坏 | 丢弃并重新调查 |
| 命令执行超时 (5min) | 展示部分输出 + 超时提示，询问是否继续等待或中断 |

**核心原则：任何错误不导致 TUI 崩溃退出，始终给用户一个可操作的回退路径。**

---

## 8. 安全边界

```
                    用户信任边界
┌───────────────────────────────────────────────────────┐
│  用户明确授权后才能执行:                                │
│  - 诊断命令 (investigate 屏逐条/批量授权)               │
│  - 危险/提权命令 (二次确认)                             │
│  - PTY 写入操作 (默认模式逐次确认)                       │
│                                                       │
│  用户需知情:                                           │
│  - 命令的风险等级和具体警告                             │
│  - PTY 接管中 LLM 即将写入的内容和理由                   │
│                                                       │
│  系统保证:                                             │
│  - API Key 仅存储在环境变量或 0600 配置文件中             │
│  - context.json 不存储密码/Token 等敏感信息             │
│  - 对话历史不持久化 (仅内存)                            │
│  - 全自动模式可由用户随时切回默认模式或中断              │
└───────────────────────────────────────────────────────┘
```

---

## 9. 待实现阶段确认的开放项

| 项 | 说明 | 影响范围 |
|----|------|----------|
| ratatui binding 能力验证 | 是否满足全屏接管、键盘导航、颜色渲染需求 | tui/ 全部 |
| nushell def 参数展开语法 | `...$args` 语法在目标 nushell 版本的实际行为 | config/shell_rc.cj |
| Cangjie FFI 与 libc 交互 | `posix_openpt` / `grantpt` / `unlockpt` / `fork` / `setsid` / `exec` 的 FFI 声明 | executor/pty.cj |
| `stdx.net.http` 流式读取能力 | `resp.body.read(buf)` 在 HTTPS + 长连接下的实际表现 | llm/sse.cj |
| 仓颉并发原语可用性 | `std.concurrent.Channel` / spawn 的实际 API 形态 | core/message_bus.cj |
| JSON Schema version 字段 | 是否需要加入 LLM 响应的 version 字段以做前向兼容 | llm/codec.cj |
