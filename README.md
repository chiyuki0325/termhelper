# 智能终端助手

本项目是一个 Linux 终端智能助手。用户用自然语言描述想做的事，它会调用大模型生成 Shell 命令，并在全屏 TUI 中展示命令、分解说明和安全提示，让用户选择运行、复制或修改。

```bash
?? 查找当前目录下最大的 10 个文件
```

本项目是对 GitHub Copilot CLI（`gh copilot`）的致敬和拓展（它已于 2025 年被微软砍掉）。termhelper 延续这种自然语言辅助终端操作的思路，并加入 TUI、安全提示、环境调查和 PTY agentic 执行能力。

本项目也是东北大学 2026 年春《仓颉社区软件工程》课程大作业，使用仓颉语言实现。

## 主要能力

- 将自然语言转换为 Shell 命令
- 展示命令用途、参数解释和安全风险
- 对危险操作给出警告
- 在信息不足时请求执行环境调查命令
- 支持交互式命令的 PTY agentic 模式
- 支持 OpenAI 兼容、Anthropic、Google 等 LLM Provider
- 支持中英文界面，按 `LANG` / `LC_ALL` 自动切换
- 支持 `?? <请求>` 形式的 Shell 集成

## 安装

准备依赖并构建：

```bash
bash scripts/setup-deps.sh
cjpm build
```

构建产物位于：

```text
target/release/bin/termhelper
```

将其安装到 $PATH 中（如 `/usr/local/bin` 或 `~/.local/bin`：

```bash
install -Dm755 target/release/bin/termhelper ~/.local/bin/termhelper
```

安装 Shell 集成：

```bash
./target/release/bin/termhelper --install
```

然后按终端提示重新加载对应的 Shell 配置文件，或重启终端。

卸载 Shell 集成：

```bash
termhelper --uninstall
```

## 配置

termhelper 需要可用的 LLM API Key。最简单的方式是设置环境变量：

```bash
export LLM_API_KEY="sk-..."
```

也可以使用 Provider 专属环境变量：

```bash
export ANTHROPIC_API_KEY="..."
export GOOGLE_API_KEY="..."
export OPENAI_API_KEY="..."
```

配置文件会自动创建在：

```text
~/.config/termhelper/config.json
```

常用配置示例：

```json
{
  "version": 1,
  "provider": "openai_compat",
  "llm": {
    "api_key": "",
    "base_url": "https://api.openai.com/v1",
    "model": "gpt-4o",
    "timeout_sec": 60,
    "structured_output_mode": "auto"
  },
  "execution": {
    "spawn_timeout_sec": 300,
    "pty_default_mode": "confirm",
    "pty_max_rounds": 50
  },
  "retry": {
    "max_retries": 3,
    "base_delay_ms": 1000,
    "max_delay_ms": 16000
  }
}
```

`provider` 可选：

| Provider | 配置值 |
| --- | --- |
| OpenAI 兼容接口 | `openai_compat` |
| Anthropic | `anthropic` |
| Google | `google` |

## 使用

直接运行：

```bash
termhelper "删除所有 tmp 开头的文件夹"
```

安装 Shell 集成后：

```bash
?? 删除所有 tmp 开头的文件夹
?? 更新系统
?? 帮我找出占用 8080 端口的进程
```

常用参数：

```bash
termhelper --help
termhelper --debug "查询内容"
```

## 开发

本项目配备了完善的 `AGENTS.md`，可采用 Codex、Claude Code 等编码代理辅助开发。

## 许可证

本项目使用 MIT License，详见 [LICENSE](./LICENSE)。
