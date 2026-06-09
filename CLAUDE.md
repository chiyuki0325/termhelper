# CLAUDE.md — termhelper

> Linux 终端智能助手。用仓颉语言编写，调用大模型将自然语言转换为可执行的 Shell 命令，辅以分解说明和安全警告。

## 项目概述

用户在终端输入 `?? <自然语言查询>`，termhelper 启动全屏 TUI，调用 LLM 生成命令，展示命令分解说明和安全等级，让用户选择运行/复制/修改。对于交互式命令（如 `sudo apt upgrade`），支持 PTY agentic 模式让 LLM 接管终端自动交互。

**核心技术栈：** 仓颉（Cangjie）1.1.0 + ratatui TUI 框架 + Rust FFI 绑定 + `stdx.net.http` HTTP 客户端

## 构建与运行

### 首次配置

```bash
# 1. 拉取第三方依赖（stdx、naivejson、ratatui），构建 Rust FFI
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
├── main.cj                          # 入口：参数解析、配置加载、TUI/调试/安装卸载分发
├── types/                           # 零依赖数据模型
│   ├── llm.cj                       # LLMResponse, CommandData, InvestigateData, SafetyLevel
│   ├── session.cj                   # Message, MessageRole, EnvironmentContext
│   └── pty.cj                       # PtyTool, PtyLoopState, PtyResult, AppEvent, CommandResult
├── core/                            # 业务编排层
│   ├── session.cj                   # Session：对话历史、LLM 交互、FactEdits 合并
│   ├── request.cj                   # RequestBuilder：system prompt + context + history + JSON Schema
│   ├── context.cj                   # ContextManager：环境上下文持久化和迁移入口
│   ├── pty_agent.cj                 # PTY agentic 循环：PTY + LLM tool-calling + 用户确认
│   ├── safety_fallback.cj           # 本地安全兜底检查
│   └── retry.cj                     # LLM 重试策略和错误分类
├── adapters/                        # LLM Provider 适配层
│   ├── provider.cj                  # Provider 抽象、ChatRequest/ChatResponse、tool-calling 类型
│   ├── openai_compat.cj             # OpenAI 兼容接口
│   ├── anthropic.cj                 # Anthropic Messages API
│   ├── google.cj                    # Google Gemini API
│   ├── structured_output.cj         # Provider-specific structured output 参数构造
│   ├── sse.cj                       # SSE 流解析器
│   └── util.cj                      # Provider/SSE 共用 JSON 工具函数
├── infra/                           # OS 和持久化基础设施
│   ├── config.cj                    # 配置加载、环境变量覆盖、默认配置落盘
│   ├── paths.cj                     # 配置和上下文路径
│   ├── fs.cj                        # 文件读写、flock 排他锁、原子写入
│   ├── file_permissions.cj          # 敏感文件 chmod 0600
│   ├── migration.cj                 # context.json 版本迁移
│   ├── spawn.cj                     # 普通子进程执行、输出捕获、超时和中断
│   ├── pty.cj                       # PTY 创建、窗口大小、master fd 读写、子进程控制
│   ├── pty_text_buffer.cj           # PTY 输出纯文本归一化、LLM 上下文 compact/delta
│   ├── terminal_buffer.cj           # 虚拟终端缓冲区和 ANSI 解析
│   ├── clipboard.cj                 # 剪贴板：OSC 52 → wl-copy → xclip → 降级展示
│   ├── shell_rc.cj                  # Shell RC install/uninstall，marker 包围
│   └── util.cj                      # debug trace、环境变量、进程/信号工具
├── tui/                             # 终端 UI 层
│   ├── tui.cj                       # TUI 初始化、主循环、Screen 路由、Channel 接收
│   ├── input.cj                     # 键盘/鼠标事件 → Action
│   ├── signal.cj                    # self-pipe 信号通知辅助
│   ├── theme.cj                     # 颜色和样式常量
│   ├── screens/
│   │   ├── loading.cj               # Loading 屏
│   │   ├── result.cj                # 命令结果屏
│   │   ├── execute.cj               # 普通 spawn 执行屏
│   │   ├── pty_agentic.cj           # PTY agentic 执行屏
│   │   ├── prompt.cj                # investigate/clarify/modify 输入屏
│   │   └── error.cj                 # 错误屏
│   └── components/
│       ├── layout.cj                # 通用布局辅助
│       ├── command_display.cj       # 命令展示
│       ├── explanation.cj           # 命令分解说明
│       ├── safety_badge.cj          # 安全等级展示
│       ├── option_menu.cj           # 选项菜单
│       ├── overlay_panel.cj         # PTY overlay 面板
│       ├── spinner.cj               # 加载动画
│       ├── styled_text.cj           # 富文本样式辅助
│       └── text_input.cj            # 文本输入/敏感输入
├── util/                            # Prompt 和 schema 工具
│   ├── prompt.cj                    # 主流程、json_object、PTY agent prompt
│   └── json_schema.cj               # LLMResponse JSON Schema
├── i18n/
│   └── i18n.cj                      # LANG/LC_ALL 语言检测和中英文 UI/prompt 文案
```

## 编码约定与注意事项

### 仓颉语言关键规则

- **`std.core` 自动导入**，无需显式 import。`String`、`Array`、`Option`、`Rune` 等均可直接用
- **`safeUtf8(Array<UInt8>)`** — PTY/终端输出进入 LLM 文本上下文时使用的容错 UTF-8 转换。已确认完整 UTF-8 的普通文件/HTTP/JSON 字节数组仍可使用 `String.fromUtf8(Array<UInt8>)`
- **`@JsonAdapter`** 宏来自 `naivejson`，为类/枚举自动生成 `serialize()`/`deserialize()`/`toJsonSchema()`
- **`@C` 结构体** 用于 FFI 场景，如 `Winsize` 用于 `ioctl(TIOCSWINSZ)`
- **`StringBuilder`** 用于高效拼接字符串，避免大量 `+` 产生中间字符串
- **`unsafe {}` 块** 包裹所有 FFI 函数调用（`read`/`write`/`fork`/`ioctl`/`close`/`kill` 等）
- **`Attribute` 用 `var` 不用 `let`**：`class` 的字段必须用 `var` 声明（即使只在构造后赋值）
- **`spawn {}`** 创建新线程，返回 `Future<T>`。用于后台 LLM 调用、子进程执行

### 字符串与 safeUtf8

项目中禁止用 `String(Rune(Int32(byte)))` 逐字节拼接字符串；这种写法会破坏多字节 UTF-8 序列，导致中文和其他非 ASCII 输出乱码。

当前 PTY LLM 文本上下文使用 `src/infra/pty_text_buffer.cj` 中的 `safeUtf8(bytes)` 做容错转换。它会保留合法 UTF-8 序列，并用替换符处理截断或非法字节，适合处理 PTY tail、delta、ANSI 剥离后的片段等不保证边界完整的终端输出：

```cangjie
// ✅ PTY/LLM 文本上下文：容错处理不完整或非法 UTF-8
safeUtf8(bytesRange(bytes, start, end).toArray())

// ❌ 错误做法：逐字节转 Rune 会破坏多字节 UTF-8
String(Rune(Int32(byte)))
```

已确认完整的 UTF-8 字节数组仍使用 `String.fromUtf8(Array<UInt8>)`，例如配置/RC 文件、SSE 行缓冲、JSON 字符串拼装等。命令 stdout/stderr 和 PTY 读取仍需注意 chunk 边界；如要把片段送入 LLM 上下文，优先经过 `PtyLlmContextBuffer` / `safeUtf8`。

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

## 第三方依赖

| 依赖 | 路径 | 说明 |
|------|------|------|
| stdx | `thirdparty/stdx/` | 仓颉扩展标准库 release 包，`setup-deps.sh` 按当前架构下载 |
| ratatui | `thirdparty/ratatui/` | Rust FFI 绑定的 TUI 框架（cangjie-ratatui-sdk + cangjie-tui-ffi） |
| naivejson | `thirdparty/naivejson/` | JSON 序列化库，提供 `@JsonAdapter` 宏和 `DataModel` 转换 |

`references/` 目录包含参考实现（claude-code SDK 源码、musl libc PTY 实现、ratatui/naivejson 的本地备份）。

### thirdparty 管理规则

`thirdparty/` 整体被主仓库 `.gitignore` 忽略，不提交第三方源码、release 包、解压产物或 Rust target 产物。第三方依赖的获取和本地修补统一由 `scripts/setup-deps.sh` 完成：

- stdx：按当前 CPU 架构下载 `cangjie_stdx` release zip，解压到 `thirdparty/stdx/<arch>_cjnative/`。
- naivejson：clone 后 patch 其 `naivejson/cjpm.toml` 中当前架构的 stdx 路径，指向本项目 `thirdparty/stdx/.../static/stdx`。
- ratatui：clone 后 patch SDK 的 Rust FFI link path，并构建 `cangjie-tui-ffi`。
- 主项目：`setup-deps.sh` 会 patch 根目录 `cjpm.toml` 的 ratatui FFI `link-option`，把提交版相对路径替换为当前 checkout 的绝对路径，供本机 `cjpm build` 使用。

绝对路径不应该进入提交。尤其是 `setup-deps.sh` 运行后，根目录 `cjpm.toml` 可能出现当前机器的绝对路径（例如 `-L.../thirdparty/ratatui/cangjie-tui-ffi/target/release`）。如果本轮需要修改并提交 `cjpm.toml`，提交前必须把这些本地 patch 恢复为仓库约定的相对路径；如果本轮没有修改 `cjpm.toml`，不要 add 它。提交前用以下命令检查：

```bash
rg -n "/home/|/Users/|Documents/Apps|cangjie-tui-ffi/target/release" cjpm.toml scripts/setup-deps.sh README.md CLAUDE.md
git diff --cached -- cjpm.toml
```

### ratatui SDK 注意事项

`thirdparty/ratatui/` 中的 Cangjie ratatui SDK 是 `gitcode.com/Cangjie-SIG/ratatui` 的 hard fork。原始 SDK 质量低劣，包含大量 stub 代码，容易导致功能静默失败。

开发时应将该 SDK 视为不可靠依赖：遇到 TUI 行为异常、FFI 返回成功但无实际渲染、事件/样式/布局接口无效等情况，不要默认业务代码有错，应主动检查并修改 `thirdparty/ratatui/`，补完 termhelper 所需功能。

## Bundled Skills 使用说明

本项目在 `.claude/skills/` 中绑定了仓颉语言相关 skills，Codex/Claude Code 等编码代理开发本项目时应优先使用这些资料，而不是凭经验猜测仓颉 API：

- `cangjie-lang-features` — 仓颉语言核心特性
- `cangjie-std` — 标准库常用功能速查
- `cangjie-stdx` — 扩展标准库功能速查（JSON、HTTP、日志、压缩、TLS 等）
- `cangjie-toolchains` — `cjc` / `cjpm` / `cjfmt` / `cjlint` 等工具链
- `cangjie-regulations` — 仓颉项目规范和最佳实践
- `cangjie-original-docs` — 原始文档兜底

实现新功能时，优先级应为：

1. 仓颉标准库 `std`。
2. 仓颉扩展标准库 `stdx`。
3. 项目已有 helper / infra 封装。
4. 第三方依赖（如 `naivejson`、`ratatui`）。
5. FFI。

不要第一反应写 FFI。只有在 `std` / `stdx` / 现有封装无法满足需求，或确实需要 POSIX/终端/PTY/底层系统能力时，才新增 FFI。新增 FFI 时必须集中声明、使用 `unsafe {}` 包裹调用、处理资源释放，并优先参考本项目已有 `infra/pty.cj`、`infra/spawn.cj`、`infra/file_permissions.cj` 的写法。

## Git Commit Format

Use English commit messages in the format `type: description`:
- `feat:` — new features
- `fix:` — bug fixes
- `refactor:` — refactoring
- `improvement:` — improvements
- `docs:` — documentation
- `chore:` — maintenance

**注意**: 对于 Claude Code，每个 commit message 末尾必须包含 `Co-Authored-By` trailer。模型名称需要参考运行环境提示中的 `You are powered by the model <实际的模型名称>`，不应该无脑认为自己是 `Claude Opus 4.8`。

对于 Codex，每个 commit message 末尾也必须包含 `Co-Authored-By` trailer，使用当前 Codex 模型身份。例如本项目当前约定为：

```text
Co-Authored-By: GPT-5.5 <codex@openai.com>
```

## Memory 文件

项目相关的持久记忆存放在 `/home/chiyuki/.claude/projects/-home-chiyuki-Projects-termhelper/memory/`，启动时通过 `MEMORY.md` 索引加载。
