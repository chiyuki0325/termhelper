# 智能终端助手（termhelper）分阶段实现计划

> 基于 [需求描述](./human-requirements.md)、[需求分析说明书 v5](./requirements-final.md)、[技术选型](./tech-selection.md)、[架构设计 v3](./architecture-final.md)

## 总体策略

**7 个阶段，每阶段产出可独立验证的增量。** 依赖关系严格：后一阶段依赖前一阶段的产出。每阶段末尾设验证关口，通过后方可进入下一阶段。各阶段内的模块可并行分派给不同人员。

核心原则：
- 先跑通最小闭环（阶段 1-2），再逐步叠加复杂能力
- 所有外部依赖（FFI、HTTP、Clipboard）集中在阶段 1 统一验证，避免后期发现不满足需求
- 每个阶段结束时具备可手动测试的产出版本
- 阶段粒度按架构分层切分：基础设施 → 适配器 → 核心 → TUI → PTY → 打磨

---

## 阶段 1：项目骨架与可行性验证

**目标：** 搭建仓颉项目骨架，验证所有关键外部依赖的能力边界，确保后续开发不因能力缺失受阻。

**产出：**
- 可编译运行的 `termhelper` 二进制（空壳 TUI，仅展示 "Hello" 后退出）
- 所有关键外部依赖的验证报告及应对方案
- `types/` 包全部数据类型定义

### 1.1 项目初始化

| 任务 | 说明 | 预估人天 | 可并行 |
|------|------|----------|--------|
| 创建 cjpm 项目骨架 | `cjpm init`，配置 `cjpm.toml`（依赖 ratatui binding），建立 `src/` 下各包子目录 | 0.5 | — |
| 定义 `types/` 全部数据类型 | `types/llm.cj`（LLMResponse / CommandData / InvestigateData / SafetyInfo 等枚举和结构体）、`types/session.cj`（Message / MessageRole / EnvironmentContext）、`types/pty.cj`（PtyTool / PtyLoopState / PtyResult）——纯数据类型，零依赖 | 1 | 是 |
| 编写 `main.cj` 入口骨架 | 命令行参数解析框架（解析 `--install` / `--uninstall` / `--help` 与自然语言查询的区分逻辑），子命令分发骨架，打印参数后退出 | 0.5 | — |

### 1.2 ratatui binding 能力验证

| 任务 | 说明 | 预估人天 | 可并行 |
|------|------|----------|--------|
| 验证 ratatui 全屏接管能力 | 测试 alternate screen 进入/退出、raw mode 终端控制、退出后终端状态恢复 | 0.5 | 是 |
| 验证键盘事件读取 | 测试 `poll_event` 的按键识别（普通字符、方向键、Esc、Ctrl-C 等组合键）、非阻塞读取模式 | 0.5 | 是 |
| 验证颜色渲染 | 测试前景色/背景色设置、粗体/下划线属性、橙色（危险警告色）渲染效果 | 0.5 | 是 |
| 验证 alternate screen 启动耗时 | 计时 alternate screen 初始化到首帧渲染完成的耗时，评估冷启动性能余量 | 0.5 | 是 |
| 验证终端 resize 事件 | 测试 SIGWINCH 到来时 ratatui 的 `terminal_size` 更新和重绘行为 | 0.5 | 是 |

### 1.3 仓颉 FFI + libc 验证（PTY 基础设施能力）

| 任务 | 说明 | 预估人天 | 可并行 |
|------|------|----------|--------|
| 验证 libc FFI 声明 | `posix_openpt` / `grantpt` / `unlockpt` / `ptsname` / `fork` / `setsid` / `exec` / `ioctl(TIOCSWINSZ)` 的 FFI 声明正确性 | 1 | 是 |
| 实现 PTY 最小可工作样例 | 创建 PTY → spawn bash → 写入 `echo hello` → 读取 master fd 输出 → 验证子进程生命周期管理（退出检测、SIGHUP 清理） | 1.5 | — |
| 验证 master fd 非阻塞读写 | 验证 `fcntl(O_NONBLOCK)` + select/epoll 模式在仓颉中的可用性 | 1 | — |

### 1.4 HTTP 客户端验证（LLM 流式调用能力）

| 任务 | 说明 | 预估人天 | 可并行 |
|------|------|----------|--------|
| 验证 `stdx.net.http` HTTPS + 流式读取 | 对真实 LLM API 端点发起 HTTPS POST，验证 `resp.body.read(buf)` 逐块读取行为、长连接稳定性 | 1 | 是 |
| 实现 SSE 协议解析器最小原型 | 解析 `data:` / `event:` / `id:` 行，处理 `[DONE]` 结束标记，验证 chunk 边界处理（一个 SSE 事件可能跨多个 read buffer） | 1 | 是 |
| 验证 HTTP 超时控制能力 | 确认 `stdx.net.http` 是否支持连接超时、读取超时、空闲超时的独立配置；若不支持，评估在仓颉中实现应用层超时的可行方案 | 1 | 是 |

### 1.5 并发原语验证

| 任务 | 说明 | 预估人天 | 可并行 |
|------|------|----------|--------|
| 验证 Channel / spawn API | 确认仓颉的 Channel 创建/发送/接收（含 `tryRecv` 非阻塞接收）和 `spawn` 的 API 形态、生命周期语义 | 0.5 | 是 |

### 1.6 其他关键能力验证

| 任务 | 说明 | 预估人天 | 可并行 |
|------|------|----------|--------|
| 验证信号处理器注册 | 仓颉中 `SIGINT` / `SIGTERM` / `SIGHUP` / `SIGWINCH` 的注册 API（signal / SigAction） | 0.5 | 是 |
| 验证 panic hook | 仓颉中注册全局 panic handler 的 API | 0.5 | 是 |
| 验证 nushell `def` 参数展开语法 | 在 nushell 中测试 `def "??" [ ...args ] { termhelper ...$args }` 的兼容性 | 0.5 | 是 |

**阶段 1 验证关口：** 全部验证项有明确结论（可用/需适应/不可用需替代方案）。验证报告归档于 `docs/`。若存在不可解的阻塞项，在此阶段终止或调整方案。

**阶段 1 总预估人天：** 10（含并行，实际日历时间约 5-7 天）

---

## 阶段 2：基础设施层

**目标：** 完成 `infra/` 包全部模块的实现和单元测试，提供稳定的基础设施 API 供上层调用。

**产出：**
- `infra/` 下全部 6 个模块（不含 migration，阶段 4 实现）
- 集成测试：创建 PTY → 写入/读取 → 销毁

### 2.1 配置管理

| 任务 | 说明 | 预估人天 | 可并行 |
|------|------|----------|--------|
| 实现 `infra/config.cj` | 配置加载器：环境变量读取（`LLM_API_KEY` 等）→ JSON 文件（`~/.config/termhelper/config.json`，权限 0600）→ 默认值三层 fallback。支持 `Config` 结构体的反序列化。若文件不存在则创建目录和默认配置文件。LLM 配置支持 `structured_output_mode`，默认 `auto`；OpenAI-compatible Provider 可设置为 `json_object` 以跳过不被兼容服务支持的 `json_schema` 请求。 | 1 | 是 |
| 实现配置首次交互式输入 | 当 API Key 无任何来源时，返回"需要配置"信号（具体 TUI prompt 由上层实现），接收用户输入后写回 config.json | 0.5 | — |

### 2.2 PTY 基础设施

| 任务 | 说明 | 预估人天 | 可并行 |
|------|------|----------|--------|
| 实现 `infra/pty.cj` | 完整 PTY 抽象：`posix_openpt` → `grantpt` → `unlockpt` → `ptsname`。封装 `Pty` 类型：创建（含终端大小设置 `TIOCSWINSZ`）、master fd 非阻塞读写、resize（窗口大小变更时更新 slave）、close（清理子进程、关闭 fd） | 2.5 | 是 |
| 实现 PTY fork/exec 子进程管理 | fork → setsid（新会话）→ 打开 slave fd → dup stdin/stdout/stderr → exec 目标命令。父进程侧管理子进程生命周期：waitpid 检测退出、SIGHUP 清理 | 2 | — |
| 实现虚拟终端缓冲区 | 维护与真实终端同等大小的字符单元格网格（每个单元格：字符 + fg/bg 颜色 + 粗体/下划线/反色属性）。支持从 PTY 输出中解析 ANSI 转义序列并更新缓冲区状态，支持滚动回视区 | 3 | 是 |
| PTY 模块集成测试 | 创建 PTY → spawn bash → 写入命令 → 验证输出 → 销毁。覆盖：exit 检测、非阻塞读、resize、异常退出清理 | 1 | — |

### 2.3 子进程执行

| 任务 | 说明 | 预估人天 | 可并行 |
|------|------|----------|--------|
| 实现 `infra/spawn.cj` | 普通子进程 spawn：command + args → fork/exec → 捕获 stdout/stderr（分离管道）。支持超时（配置的 `spawn_timeout_sec`，默认 5min），超时后 SIGTERM → 等 5s → SIGKILL。支持用户主动中断（外部信号触发 kill）。返回 `CommandResult { exitCode, stdout, stderr }`。输出逐行回调（用于 TUI 实时展示） | 2 | 是 |

### 2.4 剪贴板

| 任务 | 说明 | 预估人天 | 可并行 |
|------|------|----------|--------|
| 实现 `infra/clipboard.cj` | 剪贴板写入：检查 `WAYLAND_DISPLAY` 环境变量 → 使用 `wl-copy`；检查 `XDG_SESSION_TYPE` → 使用 `xclip`。两级降级：工具无 → 尝试 OSC 52 序列写入（需检测终端支持）；全部不可用 → 返回错误供上层展示命令文本 + 安装提示 | 1.5 | 是 |

### 2.5 Shell RC 管理

| 任务 | 说明 | 预估人天 | 可并行 |
|------|------|----------|--------|
| 实现 `infra/shell_rc.cj` | Shell RC 安装：检测 `SHELL` 环境变量 → 确定 RC 文件路径和语法（bash/zsh → alias、fish → alias 无等号、nushell → def）→ 在 RC 文件中追加注释标记包围的命令定义（`# >>> termhelper >>>` ... `# <<< termhelper <<<`）。Shell RC 卸载：定位标记注释之间的内容 → 删除整个区块（含标记行）。不修改标记区块外的任何配置 | 1.5 | 是 |

### 2.6 文件工具

| 任务 | 说明 | 预估人天 | 可并行 |
|------|------|----------|--------|
| 实现 `infra/fs.cj` | JSON 文件原子读写：`flock(LOCK_EX)` 排他锁全程持有（读-修改-写周期），序列化/反序列化 JSON，`fsync` 确保落盘后释放锁 | 1 | 是 |

**阶段 2 验证关口：** 基础设施模块单元测试全部通过。PTY 创建 → 读写 → 关闭的集成测试通过。ratatui binding 依赖在 Cargo/cjpm 中正确链接。

**阶段 2 总预估人天：** 14.5（含并行，实际日历时间约 8-10 天）

---

## 阶段 3：适配器层

**目标：** 实现 LLM Provider 抽象接口及三家实现，完成 Structured Output 适配层和 SSE 流式解析。此阶段产出可独立用 curl 风格脚本测试。

**产出：**
- 三套 LLM Provider 实现，均可通过接口完成 chat / chatStream / chatWithTools
- Structured Output 在各 Provider 上的适配封装
- SSE 流式解析器

### 3.1 Provider 接口与 SSE 解析

| 任务 | 说明 | 预估人天 | 可并行 |
|------|------|----------|--------|
| 定义 `adapters/provider.cj` LLMProvider 接口 | 三个方法：`chat`（非流式返回完整响应）、`chatStream`（流式，传入 onChunk 回调）、`chatWithTools`（tool-calling 请求，流式返回 tool_use 选择）。请求/响应类型定义 | 1 | — |
| 实现 `adapters/sse.cj` SSE 解析器 | 完整的 SSE 协议解析：逐字节从 InputStream 读取 → 按行分割 → 解析 `data:` / `event:` / `id:` / `retry:` 字段 → 处理跨 buffer 的 chunk 粘包/拆包 → 识别 `[DONE]` 结束标记 → 向上层逐个交付事件 | 1.5 | 是 |

### 3.2 OpenAI Compatible Provider

| 任务 | 说明 | 预估人天 | 可并行 |
|------|------|----------|--------|
| 实现 `adapters/openai_compat.cj` | OpenAI 协议兼容实现：构造 `/v1/chat/completions` 请求、处理 `response_format: { type: "json_schema", json_schema: {...} }` 的 Structured Output 配置、流式（`stream: true`）SSE 事件处理（`delta.content` 拼接）、非流式完整响应处理。覆盖 OpenAI / DeepSeek / Moonshot 等兼容服务。支持 `structured_output_mode=auto` 时先用 `json_schema`、遇到不支持错误自动降级为 `json_object`；支持 `structured_output_mode=json_object` 时直接使用 `json_object`，避免每次多一次失败请求。 | 2 | 是 |

### 3.3 Anthropic Provider

| 任务 | 说明 | 预估人天 | 可并行 |
|------|------|----------|--------|
| 实现 `adapters/anthropic.cj` | Anthropic Messages API 实现：构造 `/v1/messages` 请求、Structured Output 通过 `tool_use` 单工具实现（定义单个 tool 的 `input_schema` 为 JSON Schema）、流式 SSE 事件处理（`content_block_delta` / `message_delta`）、非流式处理 | 2 | 是 |

### 3.4 Google Provider

| 任务 | 说明 | 预估人天 | 可并行 |
|------|------|----------|--------|
| 实现 `adapters/google.cj` | Google Gemini API 实现：构造 `generateContent` 请求、Structured Output 通过 `response_mime_type: "application/json"` + `response_schema` 实现、流式 SSE 事件处理、非流式处理 | 2 | 是 |

### 3.5 Structured Output 适配封装

| 任务 | 说明 | 预估人天 | 可并行 |
|------|------|----------|--------|
| 实现 `adapters/structured_output.cj` | 统一 Structured Output 适配层：根据 provider 类型自动选择对应机制（OpenAI → `response_format` / Anthropic → tool_use / Google → `response_schema`），封装 JSON Schema 注入逻辑，统一的响应提取和反序列化入口。Provider 不支持 Structured Output 时降级为 `response_format: { type: "json_object" }` + 基本容错提取 | 1.5 | — |

**阶段 3 验证关口：** 三套 Provider 均可对真实 LLM 服务发起流式调用、获取响应、通过 Structured Output 机制保证 JSON Schema 合规。元测试用 mock server 验证 SSE 解析器对粘包/拆包/中断的正确处理。

**阶段 3 总预估人天：** 10（含并行，实际日历时间约 6-8 天）

---

## 阶段 4：核心层 + 上下文迁移

**目标：** 实现 `core/` 包全部模块和 `infra/migration.cj`，完成完整的 "用户输入 → LLM 调用 → 结构化响应解析 → 结果返回" 链路。此阶段产出可从命令行调用并得到 LLM 返回的 JSON 响应（无 TUI，纯 CLI 调试输出）。

**产出：**
- `core/` 下全部 5 个模块 + `util/` 下 2 个模块 + `infra/migration.cj`
- 端到端 CLI 调试入口：`termhelper --debug "查询文本"` → 打印 LLMResponse JSON

### 4.1 System Prompt 与 JSON Schema

| 任务 | 说明 | 预估人天 | 可并行 |
|------|------|----------|--------|
| 编写 `util/prompt.cj` | 主流程 System Prompt 模板：角色定义 + 命令生成规则 + 安全分析规则 + interactive 判定规则 + 输出格式约束。PTY Agent System Prompt 模板：工具集说明 + 交互规则 + 敏感输入/超时/中断判定规则。支持环境上下文占位符插值 | 1 | 是 |
| 编写 `util/json_schema.cj` | 三种 LLMResponse 变体的 JSON Schema 定义（用于 Structured Output）：`CommandData` Schema、`InvestigateData` Schema、`ClarifyData` Schema。符合各 Provider 的 Structured Output 接口要求 | 1 | 是 |

### 4.2 上下文管理与迁移

| 任务 | 说明 | 预估人天 | 可并行 |
|------|------|----------|--------|
| 实现 `infra/migration.cj` | 上下文版本迁移框架：迁移链注册机制（`v1→v2→...→vn` 的迁移函数），加载时检查 `version` 字段 → 若低于当前版本则逐版本迁移 → 若高于当前版本（降级）则丢弃并重新调查。每个迁移函数负责从 vN 到 vN+1 的字段变化（新增字段设默认值、重命名字段转换等） | 1.5 | 是 |
| 实现 `core/context.cj` ContextManager | 环境上下文持久化管理：加载 `context.json` → 版本检查 + 迁移 → 反序列化为 `EnvironmentContext`。保存：序列化 → 写入（通过 `infra/fs.cj`）。更新：合并 LLM 返回的 `factEdits` 到 `HashMap<String, EnvironmentFact>`。首次使用时做轻量本地探测并写入 facts（OS / distro / 包管理器列表 / 常用工具），但 Shell 不持久化，构造 prompt 时动态注入到 facts 之后。 | 1.5 | — |

### 4.3 会话编排与请求构造

| 任务 | 说明 | 预估人天 | 可并行 |
|------|------|----------|--------|
| 实现 `core/request.cj` RequestBuilder | 构造 LLM 请求：拼接 System Prompt + 环境上下文（JSON 序列化）+ 对话历史（Messages[]）+ JSON Schema（注入 Structured Output 配置）+ Tools 定义（PTY agentic 场景）。由 Session 调用，返回不可变请求快照供后台任务使用 | 1.5 | 是 |
| 实现 `core/session.cj` Session | 会话编排器（仅主线程持有）：维护对话历史（`ArrayList<Message>`）、追加消息（User / Assistant / Tool）、驱动 LLM 交互循环。方法：`start(query)` → 构造请求 → 后台 spawn LLM 调用；`handleResponse(response)` → 追加 Assistant 消息 → 返回下层动作（展示命令/请求调查/澄清提问）；`modify(instruction)` → 追加修改指示 → 重新发起 LLM 调用 | 2 | — |

### 4.4 安全兜底检查

| 任务 | 说明 | 预估人天 | 可并行 |
|------|------|----------|--------|
| 实现 `core/safety_fallback.cj` SafetyFallback | 本地安全兜底检查：当 LLM 返回 `safety.level = Safe` 或 `Caution` 时进行本地二次校验，扫描命令中是否包含危险模式（`rm -rf` 无 `--no-preserve-root`、`mkfs`、`dd`、`chmod 777` 等），若命中则升级为 `Danger` 警告。不替代 LLM 的安全分析，仅作兜底 | 1 | 是 |

### 4.5 LLM 重试策略

| 任务 | 说明 | 预估人天 | 可并行 |
|------|------|----------|--------|
| 实现 `core/retry.cj` | LLM 重试模块：可重试/不可重试错误分类（连接超时/5xx/429 → 可重试，401/403/400/SSE 解析错误 → 不可重试），指数退避延迟计算（`base_delay_ms * 2^(attempt-1)`，cap `max_delay_ms`，默认 1s→2s→4s→8s→16s），429 时优先使用 `Retry-After` 头。每次重试向 Channel 发送 `LLMRetrying(attempt, reason)` 通知 TUI | 1 | 是 |

**阶段 4 验证关口：** `termhelper --debug "删除所有 tmp 开头的文件"` → 从任一 Provider 获取合法的 `LLMResponse::Command` JSON，包含命令、分解说明、安全评级。环境上下文持久化并加载成功。迁移链（v1→v2）测试通过。

**阶段 4 总预估人天：** 9.5（含并行，实际日历时间约 5-7 天）

---

## 阶段 5：TUI 层 — 主流程

**目标：** 实现完整的 TUI 界面（PTY 接管屏除外），支持完整的 "用户查询 → 加载动画（流式文本）→ 结果展示 → 用户选择（运行/复制/修改）→ 普通执行 → 错误处理" 主交互流程。此阶段产出为用户可实际使用的第一个可用版本（仅非交互式命令）。

**产出：**
- `tui/` 下全部模块和 5 个 Screen（不含 `pty_agentic.cj`）+ 全部可复用组件
- termhelper v0.1-alpha：支持非交互式命令的完整流程

### 5.1 TUI 框架与主题

| 任务 | 说明 | 预估人天 | 可并行 |
|------|------|----------|--------|
| 实现 `tui/theme.cj` | 颜色常量定义：危险/提权 = 橙色 | 注意 = 黄色 | 安全/成功 = 绿色 | 错误 = 红色 | 正常信息 = 默认前景色。统一颜色获取函数，供所有 Screen 和 Component 调用 | 0.5 | — |
| 实现 `tui/input.cj` | 键盘事件 → 应用动作转换：方向键导航、Enter 确认、Esc 返回、字母快捷键（R=运行、C=复制、M=修改）、Ctrl-C 中断。统一键盘绑定映射，返回到 Screen 可消费的 Action 枚举 | 0.5 | — |
| 实现 `tui/signal.cj` | 信号处理器注册（在主线程）：SIGINT/SIGTERM/SIGHUP/SIGWINCH 的 handler → 发送内部消息通知 TUI 主循环。panic hook 注册：恢复终端模式 + 退出 alternate screen + 清理活跃 PTY + 打印崩溃信息到 stderr | 1 | — |

### 5.2 TUI 主循环

| 任务 | 说明 | 预估人天 | 可并行 |
|------|------|----------|--------|
| 实现 `tui/tui.cj` | TUI 初始化（进入 alternate screen + raw mode）、主循环（poll_event 非阻塞 50ms + Channel.tryRecv 非阻塞 + draw）、Screen 路由（根据当前 Screen 枚举分发 handle_input 和 draw）、退出清理（恢复终端模式 + 退出 alternate screen）。信号处理：SIGWINCH → 更新 terminal_size → 触发当前 Screen 重绘 | 2 | — |

### 5.3 可复用组件

| 任务 | 说明 | 预估人天 | 可并行 |
|------|------|----------|--------|
| 实现 `tui/components/command_display.cj` | 命令展示组件：语法高亮占位（命令名/参数/路径等用不同颜色或粗体区分）、可选中复制 | 0.5 | 是 |
| 实现 `tui/components/explanation.cj` | 命令分解说明组件：`BreakdownItem[]` 的两列布局渲染（组件名 | 说明），每项一行 | 0.5 | 是 |
| 实现 `tui/components/safety_badge.cj` | 安全等级徽章：Safe → 绿色盾牌 | Caution → 黄色三角 | Danger → 橙色警告 | Privilege → 红色锁图标。附带 `warnings[]` 文字渲染 | 0.5 | 是 |
| 实现 `tui/components/option_menu.cj` | 选项菜单：根据 `interactive` 字段渲染不同选项集。键盘上下导航、Enter 确认、高亮当前项。支持 `interactive: false`（运行/复制/修改）和 `interactive: true`（运行并接管/仅复制/修改）两套选项 | 0.5 | 是 |
| 实现 `tui/components/spinner.cj` | 加载动画：帧动画（`|/-\` 循环），可配置帧间隔，独立于 Screen 数据流式文本刷新 | 0.5 | 是 |
| 实现 `tui/components/text_input.cj` | 文本输入组件：单行/多行文本编辑、光标移动、普通文本输入和密码遮罩模式（`sensitive=true` 时回显 `*` 或无回显） | 1 | 是 |
| 实现 `tui/components/overlay_panel.cj` | PTY overlay 浮动面板（阶段 6 使用）：底部固定行数（3-5 行），使用 ratatui Clear + Block + Paragraph 绘制，展示状态栏（模式/轮次/用量）+ 确认弹窗（LLM 决策描述 + 确认/拒绝按钮） | 1 | 是 |

### 5.4 Screen 实现

| 任务 | 说明 | 预估人天 | 可并行 |
|------|------|----------|--------|
| 实现 `tui/screens/loading.cj` Loading 屏 | Spinner 动画 + 流式 LLM 文本实时展示区域（`LLMChunk` 追加到文本缓冲区 → `Paragraph` + 自动换行渲染 + 可滚动查看）。支持重试提示展示（`LLMRetrying` 事件 → 显示重试次数和原因）。LLMDone → 由 TUI 主循环分发到 Result/Prompt/Error | 1.5 | 是 |
| 实现 `tui/screens/result.cj` Result 屏 | 命令展示 + 分解说明 + 安全警告 + 选项菜单，组合 command_display / explanation / safety_badge / option_menu 组件。布局：上方 70% 展示命令和说明（可滚动），下方 30% 展示安全警告和选项菜单。用户选择后返回对应动作 | 1.5 | 是 |
| 实现 `tui/screens/execute.cj` Execute 屏 | 普通命令执行展示：实时追加 stdout/stderr 行（`SpawnOutput` → 滚动区域追加），展示运行状态指示器，展示最终退出码和输出摘要。支持键盘中断（Ctrl-C → 向 spawn 模块发中断信号）。子进程完成后展示完整输出（可上下滚动） | 1.5 | — |
| 实现 `tui/screens/prompt.cj` Prompt 屏 | 三种子模式：（1）Investigate：展示调查理由 + 诊断命令列表（每条附带 rationale），支持逐条授权/拒绝或批量全部授权；（2）Clarify：展示 LLM 的提问，提供文本输入区供用户回答；（3）Modify：展示当前命令文本供参考 + 文本输入区供用户输入修改指示。用户提交后触发新一轮 LLM 调用 | 2 | 是 |
| 实现 `tui/screens/error.cj` Error 屏 | 错误信息展示 + 分类图标（网络/API/超时/格式异常）。可重试错误 → 显示重试按钮 + 退出按钮。不可重试错误 → 显示配置检查提示 + 退出按钮。错误信息含原因描述和可操作的解决建议 | 1 | 是 |

**阶段 5 验证关口：** 完成 FR-02（命令生成）、FR-03（环境调查）、FR-04（命令说明）、FR-05（安全分析）、FR-06（用户交互选项）、FR-07 模式一（普通执行）和模式三（复制）、FR-08（环境上下文管理）、FR-09（对话管理）的端到端手动验证。US-01（新手删除文件）、US-03（不满意初版命令）、US-04（只想复制命令）可完整走通。

**阶段 5 总预估人天：** 12.5（含并行，实际日历时间约 8-10 天）

---

## 阶段 6：PTY Agentic 循环

**目标：** 实现 PTY agentic 循环的完整功能，包括全屏底层渲染 + overlay 面板、节流与成本控制、敏感输入处理。此阶段产出为完整功能版本（含交互式命令支持）。

**产出：**
- `core/pty_agent.cj` + `tui/screens/pty_agentic.cj` + `tui/components/overlay_panel.cj`（阶段 5 已实现）
- termhelper v0.1-beta：支持交互式命令的 PTY 接管完整流程

### 6.1 PTY Agent 核心

| 任务 | 说明 | 预估人天 | 可并行 |
|------|------|----------|--------|
| 实现 `core/pty_agent.cj` PtyAgentLoop | PTY agentic 循环完整实现：创建 PTY（通过 `infra/pty.cj`，大小 = 真实终端 W×H）→ spawn 交互式命令 → 进入循环——读 master fd（非阻塞）→ 更新虚拟终端缓冲区 → 发送 `PtyScreenUpdate` → 节流检查（距上次 LLM 调用 < 2s 或累计新增字节 < 256B 则跳过）→ 构造 LLM tool-calling 请求（system prompt + 命令上下文 + 脱敏后的历史决策 + PTY 输出 diff + tools: write/ask_user/wait/exit/interrupt + tool_choice: "required"）→ 解析 LLM 返回的 PtyTool 选择 → 执行分支。节流：最小间隔 2000ms + 最小字节 256B + 单次会话上限 50 轮 + 用量追踪（累计 prompt/completion tokens）。子进程退出 → 自动选择 Exit | 3 | — |
| 实现五类 PtyTool 的执行分支 | Write(content, reason)：默认模式 → 发送 `AwaitingConfirm` 状态 + `PtyOverlayUpdate` 到 TUI；全自动模式 → 直接写入 PTY。AskUser(question, sensitive)：发送 `AwaitingUserInput` 到 TUI；sensitive=true → 密码遮罩，用户输入结果脱敏后回传 LLM 上下文；sensitive=false → 明文回传。Wait(duration_ms)：系统 clamp 到 [500ms, 30s] → sleep → 继续循环。Exit(summary)：展示 LLM 摘要 → 结束循环 → 返回 PtyResult。Interrupt(reason)：展示原因 → 询问用户是否中断 → 中断则结束循环 | 2 | — |
| 实现轮次上限处理 | roundCount >= maxRounds(50) → 发送 `RoundLimitReached` → 暂停循环 → 展示 overlay 面板（当前输出 + LLM 调用统计 + 继续/中断/切换手动选项）→ 等待用户决策 | 0.5 | — |
| 实现敏感内容脱敏 | PTY 输出 diff 检测密码回显模式（如某些程序回显 `****` 或明文显示输入）→ 在发送给 LLM 前替换为 `[PASSWORD_REDACTED]`。AskUser(sensitive=true) 的用户输入不追加到 LLM 对话历史，替换为 `[REDACTED]` | 1 | — |

### 6.2 PTY Agentic TUI 屏

| 任务 | 说明 | 预估人天 | 可并行 |
|------|------|----------|--------|
| 实现 `tui/screens/pty_agentic.cj` PtyAgentic 屏 | 全屏 PTY 渲染为底层 + overlay 面板浮动在上层。虚拟终端缓冲区每个单元格 → ratatui Span（字符 + fg/bg 颜色 + 粗体/下划线/反色），按行组织为 Paragraph 渲染整屏。默认展示最底部（最新输出），支持用户向上滚动查看历史（PgUp/PgDn 或 ↑↓）。Overlay 面板（底部 3-5 行）展示：当前模式（默认·逐次确认/全自动）+ 轮次（N/50）+ token 用量累计 + LLM 当前决策描述 + 待确认内容。SIGWINCH → 更新虚拟终端大小 + ioctl 更新 PTY slave 窗口大小 + 触发重新渲染 | 3 | 是 |
| 实现 PTY overlay 确认交互 | PtyOverlayUpdate 驱动 overlay 面板内容更新。AwaitingConfirm 态：展示"LLM 计划写入：[内容] 理由：[理由]"，按钮 [确认写入] [拒绝] [切换到全自动]。用户选择确认 → 主线程通知 PtyAgentLoop 继续 → 写入 PTY；拒绝 → 跳过本次写入 → 继续下一轮 LLM 决策（含拒绝历史）。AwaitingUserInput 态：展示 LLM 的问题 + 密码遮罩输入区（sensitive=true 时）+ 提交按钮 | 1.5 | — |
| 实现全自动模式切换 | 用户可随时在 overlay 面板中切换"默认模式 ↔ 全自动模式"。全自动模式下 LLM 的 Write 操作不经确认直接写入 PTY，但 overlay 面板始终展示当前 LLM 决策（透明可见）。全自动模式下用户仍可随时中断命令或切回默认模式 | 1 | — |

**阶段 6 验证关口：** 完成 FR-07 模式二（PTY 接管执行）的端到端验证。US-02（开发者更新系统 — PTY 接管全流程）、US-05（不想让 LLM 接管终端 — 仅复制降级）、US-06（PTY 接管中的安全控制 — 默认模式逐次确认 → 切换到全自动）可完整走通。50 轮上限触发 → 用户继续/中断/手动切换正常。节流生效（快速输出不会导致 LLM 调用风暴）。敏感输入（sudo 密码）遮罩且不进入 LLM 上下文。

**阶段 6 总预估人天：** 12（含并行，实际日历时间约 8-10 天）

---

## 阶段 7：安装/卸载、健壮性打磨与发布

**目标：** 完成安装/卸载流程，打磨错误恢复、信号处理、异常退出恢复的健壮性，完成文档和发布准备。

**产出：**
- termhelper v1.0：完整功能 + 安装/卸载 + 生产级健壮性

### 7.1 安装与卸载

| 任务 | 说明 | 预估人天 | 可并行 |
|------|------|----------|--------|
| 完善 `main.cj` 子命令分发 | `--install` → 调用 `infra/shell_rc.cj.install()` → 输出 source 提示。`--uninstall` → 调用 `infra/shell_rc.cj.uninstall()` → 询问是否删除配置目录 → 输出结果。首次运行无配置时 → 交互式 API Key 配置引导（基础 TUI 提示界面） | 1 | 是 |
| 实现 Shell RC 安装的幂等性 | 安装前检测 RC 文件中是否已有 termhelper 标记区块 → 若有则跳过（不重复安装）或询问是否覆盖更新 | 0.5 | 是 |

### 7.2 健壮性打磨

| 任务 | 说明 | 预估人天 | 可并行 |
|------|------|----------|--------|
| 完善信号处理链路 | 各 Screen 对 SIGINT 的差异化处理：Loading → 取消当前 LLM 调用 → Error 屏；Execute → kill 子进程 → 展示部分输出；PtyAgentic → 中断 PTY → 询问是否退出；Result/Prompt/Error → 退出 TUI。SIGTERM → 优雅退出（恢复终端 + 清理 PTY + 持久化上下文）。SIGHUP → 快速退出（恢复终端模式 + 尽力清理 PTY）。测试各 Screen 下的信号响应行为 | 1.5 | — |
| 完善崩溃恢复 | panic hook 完整测试：模拟 panic → 验证终端模式恢复 + alternate screen 退出 + 活跃 PTY 子进程被 SIGHUP + 崩溃信息打印到 stderr + 进程退出。确保 panic 后终端不处于 raw mode 或 alternate screen 残留 | 1 | — |
| 完善退出流程 | 正常退出前：检查活跃后台任务（LLM 调用 / spawn / PTY）→ 提示用户确认 → 取消/中断后台任务 → context.save() 持久化 → 退出 alternate screen → 恢复终端模式 → 进程退出。Esc 键在各 Screen 中的退出行为统一 | 1 | — |
| 多实例并发安全测试 | 两个 termhelper 实例同时写 context.json → 验证 flock LOCK_EX 排他锁防止覆盖丢失。同时读 → 验证一个实例修改后另一个实例读到最新数据 | 0.5 | — |
| 极端场景测试 | 终端 0×0 → SIGWINCH 忽略。配置文件损坏 → 默认配置 + 警告。上下文文件损坏 → 丢弃 + 重新调查。LLM 全部不可用 → 错误提示 + 退出。剪贴板全部不可用 → 正确降级展示。环境上下文迁移失败 → 丢弃 + 警告 + 重新调查 | 1 | — |

### 7.3 性能与体验优化

| 任务 | 说明 | 预估人天 | 可并行 |
|------|------|----------|--------|
| 冷启动性能优化与验证 | 测量完整的 `?? <query>` 到 Loading 屏首帧的耗时，确保 ≤ 2s（不含网络部分）。若超标：分析 bottleneck（ratatui 动态库加载 / JSON 解析 / 文件 I/O），针对性优化 | 1 | 是 |
| 流式文本展示体验调优 | Loading 屏的 LLM 流式文本增量刷新流畅度调优（减少全量重绘、增量更新 Paragraph），确保无闪烁/抖动/丢帧 | 0.5 | 是 |
| PTY 渲染性能验证 | 大输出量场景（如 `find /` 的持续输出）下虚拟终端缓冲区更新和全屏渲染的性能——确保不掉帧、不阻塞 PTY master fd 的读取 | 1 | 是 |

### 7.4 文档与发布

| 任务 | 说明 | 预估人天 | 可并行 |
|------|------|----------|--------|
| 编写用户文档 | README：安装方法、使用示例（非交互式命令 / 交互式命令 PTY 接管 / 修改 / 复制）、配置说明（Provider 选择 / API Key 设置 / 超时调整）、常见问题解答 | 1 | 是 |
| cjpm 发布配置 | 完善 `cjpm.toml` 元数据、版本号、描述、许可证。确保 `cjpm build --release` 产出可分发二进制 | 0.5 | 是 |

**阶段 7 验证关口：** FR-01（接入与启动 — 安装/卸载完整流程）、FR-10（卸载与清理）端到端验证通过。NFR-01（冷启动 ≤ 2s）、NFR-02（可靠性 — 各种错误场景不崩溃）、NFR-03（安全性 — 完整安全边界）、NFR-04（可用性 — 颜色编码/错误信息）、NFR-05（可扩展性 — 多 Provider 切换）全部验证通过。全部 6 个 User Story 完整走通。

**阶段 7 总预估人天：** 10（含并行，实际日历时间约 6-8 天）

---

## 分派建议

```
阶段 1（全员参与验证）:
  ├── 人员 A：项目初始化 + types/ + main.cj 骨架 (1.1)
  ├── 人员 B：ratatui 验证 (1.2)
  ├── 人员 C：FFI/PTY 验证 (1.3)
  ├── 人员 D：HTTP/SSE 验证 (1.4)
  └── 人员 E：并发/信号/panic/nushell 验证 (1.5, 1.6)

阶段 2（基础设施，按模块分派）:
  ├── 人员 A：infra/config + infra/fs (2.1, 2.6)
  ├── 人员 B：infra/pty（核心难点，2.2）
  ├── 人员 C：infra/spawn + infra/clipboard (2.3, 2.4)
  └── 人员 D：infra/shell_rc (2.5)

阶段 3（适配器，按 Provider 分派）:
  ├── 人员 A：provider 接口 + SSE 解析器 + structured_output (3.1, 3.5)
  ├── 人员 B：openai_compat (3.2)
  ├── 人员 C：anthropic (3.3)
  └── 人员 D：google (3.4)

阶段 4（核心层，按模块分派）:
  ├── 人员 A：util/prompt + util/json_schema + core/request (4.1, 4.3 部分)
  ├── 人员 B：infra/migration + core/context (4.2)
  ├── 人员 C：core/session + core/retry (4.3 部分, 4.5)
  └── 人员 D：core/safety_fallback (4.4)

阶段 5（TUI，按 Screen 分派）:
  ├── 人员 A：tui/tui + tui/theme + tui/input + tui/signal (5.1, 5.2)
  ├── 人员 B：全部 components (5.3)
  ├── 人员 C：screens/loading + screens/result + screens/error (5.4 部分)
  └── 人员 D：screens/execute + screens/prompt (5.4 部分)

阶段 6（PTY agentic，难点集中）:
  ├── 人员 A：core/pty_agent 核心循环 + PtyTool 分支 (6.1)
  ├── 人员 B：tui/screens/pty_agentic 全屏渲染 + overlay 交互 (6.2)
  └── 两人紧密协作，建议 pair programming 关键路径

阶段 7（打磨发布）:
  ├── 人员 A：安装/卸载 + 健壮性打磨 (7.1, 7.2)
  ├── 人员 B：性能优化 + 文档发布 (7.3, 7.4)
```

---

## 总人天与里程碑

| 阶段 | 名称 | 预估人天 | 累计人天 | 关键产出物 |
|------|------|----------|----------|------------|
| 1 | 项目骨架与可行性验证 | 10 | 10 | 验证报告 + types/ |
| 2 | 基础设施层 | 14.5 | 24.5 | infra/ 全部模块 |
| 3 | 适配器层 | 10 | 34.5 | 三套 Provider + SSE |
| 4 | 核心层 | 9.5 | 44 | core/ + util/ + 端到端 CLI |
| 5 | TUI 主流程 | 12.5 | 56.5 | v0.1-alpha（非交互式命令） |
| 6 | PTY Agentic 循环 | 12 | 68.5 | v0.1-beta（完整功能） |
| 7 | 安装/卸载与打磨 | 10 | 78.5 | v1.0（生产就绪） |

**总估算：约 78.5 人天。** 以 2-4 人团队计算，日历时间约 8-12 周（含缓冲）。

---

## 风险管理

| 风险 | 影响阶段 | 缓解措施 |
|------|----------|----------|
| ratatui binding 能力不足（不支持 alternate screen / 键盘事件 / 颜色） | 1→5 | 阶段 1 优先验证；fallback：自绘 ANSI 序列替代，或评估其他仓颉 TUI 方案 |
| 仓颉 FFI 不支持某些 libc 函数（如 `posix_openpt` / `ioctl`） | 1→2 | 阶段 1 优先验证；fallback：调用外部 C helper 程序桥接 |
| `stdx.net.http` 流式读取或超时控制不满足需求 | 1→3 | 阶段 1 优先验证；fallback：使用仓颉 socket API 自行实现 HTTP 客户端 |
| 虚拟终端 ANSI 解析器实现复杂度超预期 | 2→6 | 阶段 2 中评估；fallback：降级为行缓冲模式（每行刷新，不保留 ANSI 颜色/属性），牺牲视觉一致性 |
| Structured Output 某 Provider 不支持 | 3→4 | stage 3 中验证；fallback：降级为 `response_format: json_object` + 容错提取；对 OpenAI-compatible Provider 提供 `structured_output_mode=json_object` 配置，允许用户绕过已知不支持 `json_schema` 的兼容服务 |
| 仓颉 Channel / spawn / tryRecv API 不符合预期 | 1→4 | 阶段 1 优先验证；fallback：用互斥锁 + 条件变量替代 Channel 模式 |
| PTY 节流策略导致交互延迟过高 | 6 | 阶段 6 中参数可调（interval / byte threshold），根据实际体验调整 |
