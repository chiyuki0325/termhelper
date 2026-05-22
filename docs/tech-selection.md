# 智能终端助手 技术选型文档

> 基于 [需求分析说明书 v5](./requirements-final.md)

## 选型总览

| 模块 | 选型 | 说明 |
|------|------|------|
| 编程语言 | 仓颉（Cangjie）1.1.0 | 项目约束 |
| 构建工具 | cjpm | 仓颉包管理器 |
| TUI 框架 | ratatui binding | https://gitcode.com/Cangjie-SIG/ratatui，实现阶段验证 |
| HTTP 客户端 | `stdx.net.http` | `resp.body` 为 `InputStream`，逐块读取 + 自实现 SSE 协议解析 |
| PTY | FFI 手操 `/dev/ptmx` | 参考 musl libc 的 openpty 实现，核心调用链：`posix_openpt` → `grantpt` → `unlockpt` → fork child |
| JSON | `stdx.encoding.json.stream` | `JsonSerializable` / `JsonDeserializable<T>` 接口，需手动实现（无自动派生） |
| 剪贴板 | spawn `wl-copy` / `xclip` | 根据 `WAYLAND_DISPLAY` / `XDG_SESSION_TYPE` 环境变量选择；工具缺失时降级为展示命令 |
| 配置存储 | 环境变量优先 → JSON 文件 fallback → 提示配置 | 文件路径 `~/.config/termhelper/config.json`，权限 `0600` |
| 并发策略 | 多实例允许 | 上下文文件读写加文件锁（`flock`），读共享写互斥 |
| 命令超时 | `interactive:false` 默认 5min，超时后可续；`interactive:true` 不限时 | 均可手动中断 |

## 各模块要点

### HTTP 客户端 — `stdx.net.http`

- 支持 HTTP/1.0、1.1、2.0
- HTTPS 需配置 `TlsClientConfig`（依赖 OpenSSL 3）
- 响应体原生 `InputStream`，支持 `resp.body.read(buf)` 逐块读取
- SSE 协议在上层自实现：`data:` / `event:` / `id:` 行解析
- LLM 流式调用流程：POST 请求 `Accept: text/event-stream` → 逐块读 body → 解析 SSE → TUI 实时渲染

### PTY — FFI 手操

- 不依赖第三方 PTY 库
- 核心 libc 调用：`posix_openpt(O_RDWR | O_NOCTTY)` → `grantpt` → `unlockpt` → `ptsname` 获取 slave 路径
- 子进程：fork → setsid → 开 slave fd → dup stdin/stdout/stderr → exec
- 父进程：读写 master fd，非阻塞模式 + epoll/select 事件循环
- LLM 决策循环：读 master → LLM 分析输出 → 用户确认 → 写 master → 继续

### JSON — `stdx.encoding.json.stream`

- 场景一：LLM 响应解析，按 `type` 字段分发三种结构（command / investigate / clarify）
- 场景二：环境上下文文件 `~/.config/termhelper/context.json` 的读写
- 需手动实现 `JsonSerializable` 和 `JsonDeserializable<T>` 接口
- 内置支持 `Int64`、`String`、`Bool`、`Array<T>`、`HashMap<String, T>`、`Option<T>` 等基础类型

### 配置与安全

- API Key 读取顺序：环境变量 (`$OPENAI_API_KEY` 等) → `config.json` → 无配置则 TUI 提示用户
- 配置文件 `0600` 权限，不存储密钥以外的敏感信息
- 危险命令二次确认，诊断命令需用户授权，PTY 接管默认逐次确认

### 待实现阶段验证

- ratatui binding 是否满足全屏接管、键盘导航、颜色渲染需求
- nushell alias 兼容性
- JSON schema version 字段是否需要加入
