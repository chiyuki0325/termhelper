# CLAUDE.md — termhelper

> Linux 终端智能助手。用仓颉语言编写，调用大模型将自然语言转换为可执行的 Shell 命令，辅以分解说明和安全警告。

## 项目概述

用户在终端输入 `?? <自然语言查询>`，termhelper 启动全屏 TUI，调用 LLM 生成命令，展示命令分解说明和安全等级，让用户选择运行/复制/修改。对于交互式命令（如 `sudo apt upgrade`），支持 PTY agentic 模式让 LLM 接管终端自动交互。

**核心技术栈：** 仓颉（Cangjie）1.1.0 + ratatui TUI 框架 + Rust FFI 绑定 + `stdx.net.http` HTTP 客户端

## 构建与运行

### 首次配置

```bash
# 1. 拉取第三方依赖（naivejson、ratatui），构建 Rust FFI
bash scripts/setup-deps.sh

# 2. 编译项目
cjpm build

# 3. 运行（需要设置 API Key）
export LLM_API_KEY="sk-xxx"
./target/release/bin/termhelper "删除所有 tmp 开头的文件夹"
```

### 日常开发

```bash
cjpm build                          # 编译（输出到 target/release/bin/termhelper）
cjpm build --verbose                # 查看完整编译命令
./target/release/bin/termhelper "查询内容"       # 构建后运行
./target/release/bin/termhelper --help          # 查看帮助
./target/release/bin/termhelper --tui-demo      # 彩色样式预览
./target/release/bin/termhelper --debug "查询"  # CLI 调试模式，打印 LLMResponse JSON
```

当前构建将 stdx、ratatui SDK、ratatui Rust FFI 和仓颉运行时静态链接进主程序；发行版自带的系统 C/C++ 运行库仍保持动态依赖。

### 配置文件

`~/.config/termhelper/config.json`（自动创建，权限 0600）：

```jsonc
{
  "version": 1,
  "provider": "openai_compat",       // openai_compat | anthropic | google
  "llm": {
    "api_key": "",                   // 也可用环境变量 LLM_API_KEY / OPENAI_API_KEY
    "base_url": "https://api.openai.com/v1",
    "model": "gpt-4o",
    "timeout_sec": 60,
    "structured_output_mode": "auto" // auto | json_object | json_schema
  },
  "execution": {
    "spawn_timeout_sec": 300,
    "pty_default_mode": "confirm",   // confirm | full_auto
    "pty_max_rounds": 50
  },
  "retry": { "max_retries": 3, "base_delay_ms": 1000, "max_delay_ms": 16000 }
}
```

### LLM Provider 支持

| Provider | 配置值 | Structured Output 机制 |
|----------|--------|----------------------|
| OpenAI 兼容（含 DeepSeek 等） | `openai_compat` | `response_format: json_schema`，不支持时降级为 `json_object` + prompt |
| Anthropic | `anthropic` | `tool_use` 单工具（`input_schema` = response schema） |
| Google | `google` | `response_schema` + `response_mime_type: application/json` |

## 架构设计

### 四层架构

```
入口 (main.cj)  →  TUI 层 (tui/)  →  核心层 (core/)  →  适配器层 (adapters/)
                              ↓                        →  基础设施层 (infra/)
                        Channel<AppEvent>               →  工具层 (util/)
                        (后台 → TUI 单向)
                              ↑
                        types/ (零依赖，纯数据)
```

**包依赖规则：**
- `types/` — 零依赖，被所有包引用。定义 LLM 类型、会话模型、PTY agentic 类型、AppEvent 等
- `core/` — 依赖 adapters 接口（不依赖具体实现）、infra、util
- `tui/` — 依赖 core、infra
- `adapters/` — 不依赖 core/tui（仅依赖 types）
- `infra/` — 不依赖 core/adapters/tui（仅依赖 types）
- `util/` — 不依赖其他业务包

### 线程模型

**核心原则：Session（对话历史）仅主线程持有。** 后台任务通过 Channel<AppEvent> 单向通知 TUI。

```
Main Thread (TUI)                    Background Tasks
┌──────────────────────┐            ┌──────────────────────┐
│ ratatui 事件循环      │  Channel  │ LLM Task             │
│ pollEvent + draw      │◄─────────│ HTTP 请求 + SSE 解析  │
│ Channel.tryRecv()     │           │ Structured Output    │
│ session.append()      │           │ 重试逻辑             │
│ 键盘 → Action 分发    │           └──────────────────────┘
└──────────────────────┘            ┌──────────────────────┐
                                    │ Executor Task        │
                                    │ spawn 子进程         │
                                    │ PTY I/O 读写        │
                                    │ PTY agentic 循环    │
                                    └──────────────────────┘
```

### 屏幕状态机

```
START → Loading ──┬──→ Result ──┬──→ Execute ──→ Result
                  │             ├──→ PTY Agentic
                  ├──→ Prompt   │   (交互式命令)
                  │   (Investigate/Clarify/Modify)
                  └──→ Error    └──→ 退出 Shell
```

- **Loading** — spinner + 流式 LLM 文本实时展示
- **Result** — 命令 + 分解说明 + 安全警告 + 选项菜单（运行/复制/修改/退出）
- **Execute** — 普通 spawn 执行，实时滚动输出
- **Prompt.Investigate** — 环境调查：LLM 提出诊断命令，用户逐条/批量授权
- **Prompt.Clarify** — LLM 询问澄清
- **Prompt.Modify** — 用户修改命令
- **Error** — 错误展示 + 重试/退出

### LLM 调用流程

```
Session.start(query)
  → RequestBuilder.build()          // system prompt + context + history + JSON Schema
  → LLMProvider.chat(chatRequest)   // 多态分派到具体 Provider
    → HTTP POST + Structured Output 配置
    → 响应校验（json_schema / json_object）
    → parseLLMResponseJson() → LLMResponse（Command/Investigate/Clarify）
  → Session.handleResponse()        // SafetyFallback 兜底 + FactEdits 合并
    → SessionAction（ShowCommand/RequestInvestigate/AskClarify/Error）
```

### PTY Agentic 循环（交互式命令）

交互式命令（`interactive: true`）走 PTY agentic 循环，核心流程：
1. `infra/pty.cj` 创建 PTY（`/dev/ptmx` + fork + exec），设置 `TIOCSWINSZ`
2. 非阻塞读 master fd → LLM tool-calling 分析输出（write/ask_user/wait/exit/interrupt）
3. 写 master fd → 继续读，子进程退出则结束
4. 节流控制：最小调用间隔 2000ms、最小新增字节 256、最大 50 轮

## 源码目录结构

```
src/
├── main.cj                    # 入口：参数解析、配置加载、TUI 启动
├── types/
│   ├── llm.cj                 # LLMResponse, CommandData, InvestigateData, SafetyLevel
│   ├── session.cj             # Message, MessageRole, EnvironmentContext
│   └── pty.cj                 # PtyTool, PtyLoopState, PtyResult, AppEvent, CommandResult
├── tui/
│   ├── tui.cj                 # TUI 初始化、主循环、Screen 路由、Channel 接收、渲染
│   ├── input.cj               # 键盘事件 → Action 转换（含鼠标滚轮）
│   ├── theme.cj               # 颜色常量定义
│   ├── screens/               # 各屏幕的渲染函数（纯文本 + ratatui styled 各一套）
│   └── components/            # 可复用组件（spinner、option_menu、text_input 等）
├── core/
│   ├── session.cj             # Session：对话历史管理、LLM 交互编排（仅主线程）
│   ├── context.cj             # ContextManager：环境上下文持久化（JSON + flock 排他锁）
│   ├── request.cj             # RequestBuilder：构造 LLM 请求
│   ├── safety_fallback.cj     # LLM 未标记危险时的本地兜底检查
│   └── retry.cj               # LLM 重试策略（指数退避 + HTTP 状态码分类）
├── adapters/
│   ├── provider.cj            # LLMProvider 多态分派 + ChatRequest/ChatResponse/StreamEvent
│   ├── openai_compat.cj       # OpenAI 协议兼容实现
│   ├── anthropic.cj           # Anthropic 协议实现
│   ├── google.cj              # Google 协议实现
│   ├── sse.cj                 # SSE 协议解析器
│   └── structured_output.cj   # 各 Provider 的 Structured Output 适配封装
├── infra/
│   ├── pty.cj                 # PTY 基础设施：openpt/fork/exec/master fd 读写
│   ├── spawn.cj               # 普通子进程 spawn（stdout/stderr 捕获 + 超时 + 可中断）
│   ├── config.cj              # 配置加载（env → JSON → 自动创建）
│   ├── clipboard.cj           # 剪贴板（OSC 52 → wl-copy → xclip → 降级展示）
│   ├── shell_rc.cj            # Shell RC 管理（install/uninstall，注释标记包围）
│   ├── fs.cj                  # 文件工具（JSON 读写 + flock LOCK_EX + 原子写入）
│   ├── migration.cj           # ContextMigration：逐版本数据迁移
│   ├── paths.cj               # 路径常量（~/.config/termhelper/）
│   ├── util.cj                # 调试跟踪、环境变量获取
│   └── terminal_buffer.cj     # 虚拟终端缓冲区（ANSI 解析 + 单元格渲染）
├── util/
│   ├── prompt.cj              # System prompt 模板（json_schema 模式 / json_object 模式 / PTY agent）
│   └── json_schema.cj         # LLM 响应的 JSON Schema 定义（用于 Structured Output）
├── i18n/
│   └── i18n.cj                # 国际化：根据 LANG/LC_ALL 自动切换中英文
└── tests/                     # 验证测试（FFI PTY、HTTP、并发、信号）
```

## 编码约定与注意事项

### 仓颉语言关键规则

- **`std.core` 自动导入**，无需显式 import。`String`、`Array`、`Option`、`Rune` 等均可直接用
- **`String.fromUtf8(Array<UInt8>)`** — 正确的 UTF-8 字节数组 → 字符串转换方式。**禁止** `String(Rune(Int32(byte)))` 逐字节转换（会破坏多字节 UTF-8 序列导致乱码）
- **`@JsonAdapter`** 宏来自 `naivejson`，为类/枚举自动生成 `serialize()`/`deserialize()`/`toJsonSchema()`
- **`@C` 结构体** 用于 FFI 场景，如 `Winsize` 用于 `ioctl(TIOCSWINSZ)`
- **`StringBuilder`** 用于高效拼接字符串，避免大量 `+` 产生中间字符串
- **`unsafe {}` 块** 包裹所有 FFI 函数调用（`read`/`write`/`fork`/`ioctl`/`close`/`kill` 等）
- **`Attribute` 用 `var` 不用 `let`**：`class` 的字段必须用 `var` 声明（即使只在构造后赋值）
- **`spawn {}`** 创建新线程，返回 `Future<T>`。用于后台 LLM 调用、子进程执行

### 字符串与 UTF-8

**这是最近修复的关键 bug。** 项目中从命令输出读取原始字节后，必须使用 `String.fromUtf8(Array<UInt8>)` 进行批量 UTF-8 解码：

```cangjie
// ✅ 正确做法（src/infra/spawn.cj 中的 ptrToUtf8 函数）
let arr = Array<UInt8>(n, repeat: 0)
for (i in 0..n) { arr[i] = ptr.read(i) }
String.fromUtf8(arr)

// ❌ 错误做法——会导致非 ASCII 字符乱码
String(Rune(Int32(byte)))
```

涉及文件：`src/infra/spawn.cj`（`ptrToUtf8` 辅助函数 + 4 处调用点）、`src/infra/pty.cj`（`tryRead` 方法）。

### JSON 序列化

项目使用 `naivejson` 库（thirdparty）进行 JSON 序列化：
- 带 `@JsonAdapter` 的类型自动实现 `Serializable<DataModel>` 和 `JsonSchema` 接口
- **`@JsonIgnore`** 标注运行时字段（如 `DiagnosticCommand.authorized`），不参与序列化
- **`@JsonIgnoreNull`** 使得 `Option<T>` 为 `None` 时不出现在 JSON 输出中
- **`@JsonName["alt_name"]`** 自定义字段名映射
- LLMResponse 是 **payloaded enum（无 @JsonAdapter）**，需手动 dispatch 解析

### 配置加载优先级

1. Provider 专属环境变量（`ANTHROPIC_API_KEY` / `GOOGLE_API_KEY`）
2. 通用环境变量（`LLM_API_KEY`，其次 `OPENAI_API_KEY`）
3. `~/.config/termhelper/config.json` → `llm.api_key`
4. 无配置时 TUI 提示

### 文件锁

`context.json` 读写全程使用 `flock(LOCK_EX)` 排他锁，防止多实例丢失更新。

### 国际化

`src/i18n/i18n.cj` 根据 `LC_ALL`/`LANG` 环境变量自动切换中英文。UI 文本通过 `uiText(key)` 获取，prompt 中的 few-shot examples 也随语言切换。

### 调试跟踪

`src/infra/util.cj` 提供 `debugTrace(msg)` 和 `enableDebugTrace()`。CLI 调试模式（`--debug`）会将完整 LLMResponse JSON 打印到 stdout。

## 待实现的功能（根据架构文档）

架构文档（`docs/architecture-final.md`）中规划但尚未完整实现的功能：

- **PTY Agentic 全屏渲染** — 虚拟终端 ANSI 解析 + ratatui overlay 面板（当前 execute 屏仅简单 spawn）
- **信号处理** — SIGWINCH 终端大小变化、SIGINT/SIGTERM 优雅退出、panic hook
- **`--install` / `--uninstall`** — Shell 集成安装/卸载（当前为占位实现）
- **流式 LLM 文本展示** — Loading 屏实时展示 LLM 生成内容（当前 Loading 屏为基本实现）
- **PTY 敏感输入处理** — `AskUser(sensitive=true)` 的密码遮罩和脱敏
- **Structured Output 降级链** — `json_schema` → `json_object` + prompt 的自动降级（已有框架但可能未完整测试）

## 第三方依赖

| 依赖 | 路径 | 说明 |
|------|------|------|
| ratatui | `thirdparty/ratatui/` | Rust FFI 绑定的 TUI 框架（cangjie-ratatui-sdk + cangjie-tui-ffi） |
| naivejson | `thirdparty/naivejson/` | JSON 序列化库，提供 `@JsonAdapter` 宏和 `DataModel` 转换 |

`references/` 目录包含参考实现（claude-code SDK 源码、musl libc PTY 实现、ratatui/naivejson 的本地备份）。

## Git 提交格式

项目使用中文提交信息，格式为 `type: description`：
- `feat:` — 新功能
- `fix:` — 修复
- `refactor:` — 重构
- `improvement:` — 改进/优化
- `docs:` — 文档
- `chore:` — 杂务

提交末尾加 `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`。

## Memory 文件

项目相关的持久记忆存放在 `/home/chiyuki/.claude/projects/-home-chiyuki-Projects-termhelper/memory/`，启动时通过 `MEMORY.md` 索引加载。
