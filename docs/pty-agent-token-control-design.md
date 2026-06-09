# PTY Agent Token 控制设计方案

## 背景

当前 `src/core/pty_agent.cj` 的 PTY agent 循环存在明显 token 浪费：

1. 节流逻辑只限制最小调用间隔，超过间隔后即使没有新输出也会放行 LLM 调用。
2. 新增输出超过字节阈值会提前放行，刷屏场景反而更容易高频调用。
3. 每轮请求都会把完整 PTY 文本缓冲发送给 LLM，终端历史越长，单次请求越贵。
4. 面向 LLM 的 `PtyTextBuffer` 目前主要做 ANSI 剥离，如果没有处理 `\r` 和 ANSI 光标覆盖语义，下载/编译进度条会在 prompt 中累积成大量重复行。

本方案目标是把 PTY agent 改成事件驱动，并用 compact 代替滑动窗口，降低调用频率和单次上下文大小。

## 设计原则

- 不使用滑动窗口。不要在每次追加或读取时删除头部、移动大块内存或重写大段历史。
- 超过阈值后执行一次 compact。compact 将旧输出压缩为检查点摘要，保留尾部上下文，之后继续 append。
- LLM 调用由事件触发。只有终端状态发生变化并稳定后才调用，不按固定时间空转。
- Prompt 上下文有硬上限。单轮只发送检查点摘要、上轮以来的增量和 compact 后尾部。
- LLM buffer 必须理解终端覆盖语义。`\r` 进度条、ANSI 清行、光标回退更新不能堆成历史金字塔。
- 保留 TUI 渲染路径。完整原始 PTY 输出继续用于屏幕显示和最终结果；发送给 LLM 的上下文是成本受控视图。

## 非目标

- 不实现逐字节滑动截断。
- 不要求 LLM 看到完整终端历史。
- 不把 token 控制依赖于模型供应商的 prompt cache。
- 不改变 TUI 的原始 PTY 渲染链路。

## 现有问题定位

`PtyAgentLoop.shouldThrottle()` 的当前行为是：

- `now - lastLlmCallTime < minIntervalMs` 时才节流。
- 如果新增输出超过 `minBytesThreshold`，会提前放行。
- 超过 `minIntervalMs` 后始终放行，即使没有任何新输出。

这使得刷屏时更容易触发 LLM 调用，而静默时也可能空转。

`PtyAgentLoop.callLlmForDecision()` 当前使用完整文本：

```cangjie
buf.toPlainText()
```

这会把完整历史输出放进每轮 prompt。即使决策只需要最后几行，也会重复支付全部历史 token。

另外，`PtyTextBuffer` 当前注释目标是“剥离 ANSI 转义序列后的纯文本”。如果它只是把控制序列删除，而不是执行终端语义，那么这类输出会出现问题：

```text
Downloading 1%\rDownloading 2%\rDownloading 3%\r
```

错误的 LLM 文本会变成：

```text
Downloading 1%Downloading 2%Downloading 3%
```

甚至在某些处理方式下变成多行堆叠。ANSI 进度条也类似：

```text
\x1b[2K\rProgress 10%
\x1b[2K\rProgress 20%
```

如果只 strip ANSI，会丢掉“清行”和“回到行首”的语义，导致 LLM 看到大量无意义重复进度状态。

## 总体方案

引入三层控制：

1. `PtyDecisionScheduler`：判断什么时候允许调用 LLM。
2. `PtyLlmContextBuffer`：维护面向 LLM 的 compact 后文本视图。
3. `TerminalTextNormalizer`：将 PTY 字节流归一化为适合 LLM 的文本事件，正确处理进度条和覆盖式输出。

主循环读取 PTY 输出后只做 append、归一化和状态标记。scheduler 在输出静默窗口结束、存在新信息且到达最早调用时间后，才允许进入 LLM 决策。

LLM 请求不再读取完整 `PtyTextBuffer.toPlainText()`，而是读取 compact 后上下文：

```text
checkpoint_summary
recent_text_after_compact
delta_since_last_llm_call
command
round
```

其中 `recent_text_after_compact` 是 compact 时一次性保留下来的尾部，不做持续滑动裁剪。

## 调用调度设计

新增状态字段：

```text
lastOutputAt          最近一次读到 PTY 输出的时间
firstDirtyOutputAt    本轮 dirty 周期第一次读到输出的时间
lastDecisionAt        最近一次 LLM 调用时间
lastObservedSize      最近一次调度器观察到的 buffer size
lastSentOffset        最近一次发送给 LLM 后的归一化输出 offset
dirtyOutput           上次 LLM 调用后是否有新输出
nextEligibleAt        Wait 工具或退避逻辑设置的最早调用时间
quietWindowMs         输出静默窗口，建议默认 800ms
maxWaitAfterOutputMs  输出持续变化时的最大等待，建议默认 5000ms
minDecisionIntervalMs 两次 LLM 调用的最小间隔保护，可复用旧 pty_min_interval_ms
```

判断规则：

```text
if childExited:
    allow final decision

if !dirtyOutput:
    deny

if now < nextEligibleAt:
    deny

if now - lastDecisionAt < minDecisionIntervalMs:
    deny

if now - lastOutputAt < quietWindowMs:
    if now - firstDirtyOutputAt < maxWaitAfterOutputMs:
        deny

if currentOffset == lastSentOffset:
    deny

allow
```

持续刷屏时最多等待 `maxWaitAfterOutputMs`，然后调用一次。调用后重新记录 dirty 周期，不会因为每 256B 输出就高频调用。

## Wait 工具语义

`Wait(milliseconds)` 不再等价于 sleep 后立刻调用 LLM。

执行 Wait 后：

```text
nextEligibleAt = now + clamp(milliseconds, 500, 30000)
```

主循环继续读取 PTY 输出、处理 resize 和中断。到达 `nextEligibleAt` 后仍需要满足“有新输出或进程退出”的条件。这样可以避免模型连续返回 Wait 造成 token 空转。

## 终端文本归一化

LLM buffer 不能只做 ANSI strip。它需要把终端覆盖式输出转换为“当前可见语义 + 少量关键历史”。

### 需要支持的控制语义

至少支持：

- `\r`：回到当前行行首，后续文本覆盖当前行。
- `\b`：退格，删除或覆盖前一个字符。
- `\n`：提交当前行，进入下一行。
- `ESC[K` / `ESC[0K`：从光标清到行尾。
- `ESC[1K`：从行首清到光标。
- `ESC[2K`：清整行。
- `ESC[G` / `ESC[nG` / `ESC[0G`：移动到指定列。实现中将缺省参数和 `0` 都归一化为第 0 列，用于兼容常见进度条的 `\x1b[0G` 行首刷新写法。
- `ESC[nD` / `ESC[nC`：左右移动光标。
- 常见 SGR 颜色序列：忽略样式但不能破坏文本。

可以先不实现完整虚拟终端，但必须覆盖进度条常用控制序列。后续可复用或抽取 `TerminalBuffer` 的解析能力，避免 TUI 和 LLM 两套解析器长期分叉。

### 行状态模型

归一化器维护一个当前行和已提交行：

```text
currentLine: mutable char cells
cursorCol: Int64
committedLines: append-only text events
lastProgressLine: ?String
progressUpdateCount: Int64
```

处理规则：

- 普通字符写入 `currentLine[cursorCol]`，然后 `cursorCol += 1`。
- `\r` 只把 `cursorCol = 0`，不提交新行。
- `ESC[2K` 清空 `currentLine`，`cursorCol = 0`。
- `\n` 将当前行提交到 `committedLines`，清空当前行。
- 如果一行被多次 `\r` 或清行覆盖，只保留最后可见版本。

### 进度条压缩

进度条不应该按每次刷新进入 LLM 上下文。归一化器应识别覆盖式更新：

```text
same physical line updated by \r / ESC[K / ESC[2K
```

在上下文中表示为：

```text
[progress updated 184 times, latest: Downloading 73% 14.2MB/s]
```

当后续出现 `\n` 或进入新的非覆盖行时，再提交最新进度状态。这样 LLM 能知道程序在推进，但不会看到 184 条重复进度。

### ANSI 进度条示例

输入：

```text
\x1b[2K\rDownloading 10%
\x1b[2K\rDownloading 20%
\x1b[2K\rDownloading 30%
```

LLM 文本应为：

```text
[progress updated 3 times, latest: Downloading 30%]
```

输入：

```text
Downloading 10%\rDownloading 20%\rDownloading 30%\nDone
```

LLM 文本应为：

```text
[progress updated 3 times, latest: Downloading 30%]
Done
```

不能变成：

```text
Downloading 10%
Downloading 20%
Downloading 30%
Done
```

也不能变成：

```text
Downloading 10%Downloading 20%Downloading 30%
Done
```

## Compact Buffer 设计

新增一个面向 LLM 的 buffer，不替代原始 TUI 输出路径。

```text
class PtyLlmContextBuffer
    normalized: ArrayList<UInt8>
    compactedPrefix: String
    baseOffset: Int64
    lastSentOffset: Int64
    compactThresholdBytes: Int64
    compactKeepBytes: Int64
    compactCount: Int64
    normalizer: TerminalTextNormalizer
```

字段含义：

- `normalized`：compact 后继续 append 的归一化文本段。
- `compactedPrefix`：旧输出被 compact 后形成的检查点摘要。
- `baseOffset`：`normalized[0]` 对应的全局归一化输出 offset。
- `lastSentOffset`：上次 LLM 请求发送到的全局 offset。
- `compactThresholdBytes`：触发 compact 的阈值，建议默认 128KB。
- `compactKeepBytes`：compact 时一次性保留的尾部，建议默认 24KB。
- `normalizer`：负责把 PTY 原始字节转成不会堆叠进度条的文本事件。

不做滑动窗口的关键点：

- append 只追加归一化后的文本事件到 `normalized`。
- `normalized.size > compactThresholdBytes` 时才 compact 一次。
- compact 时创建新 `normalized = tail(oldNormalized, compactKeepBytes)`，更新 `baseOffset`。
- compact 之间不移动、不裁剪、不重排已有数据。

这样不会在每轮读取或每次 prompt 构造时搬移大块历史，也不会频繁破坏系统页缓存和磁盘缓存局部性。

## Compact 触发流程

读取 PTY 输出后：

```text
events = normalizer.feed(data)
buffer.append(events)

if buffer.normalizedSize() > compactThresholdBytes:
    buffer.compact()
```

compact 逻辑：

```text
removed = normalized excluding last compactKeepBytes
tail = last compactKeepBytes of normalized

compactedPrefix = buildCheckpointSummary(
    previous = compactedPrefix,
    removed = removed
)

baseOffset += normalized.size - tail.size
normalized = tail
lastSentOffset = max(lastSentOffset, baseOffset)
compactCount += 1
```

第一版不需要额外 LLM 摘要，使用确定性摘要：

```text
[Earlier terminal output compacted: 104KB removed.
Important retained facts:
- latest progress before compact: Downloading 73% 14.2MB/s
- recent prompt: none
- recent errors: none]
```

本地规则应优先保留：

- 包含 `error:`, `failed`, `denied`, `permission`, `not found` 的行。
- 最近的 prompt 行，例如以 `?`, `:`, `[Y/n]`, `password` 结尾。
- 最近的进度状态。
- 最近 N 行非空输出。

后续如果需要更高质量摘要，可以只在 compact 时调用一次低成本 summarizer，但默认不引入额外模型调用。

## LLM 上下文构造

每轮请求构造：

```text
Command:
<command>

Terminal checkpoint:
<compactedPrefix or "No compacted history.">

Recent terminal output:
<current normalized text after compact>

New output since your previous decision:
<normalized text from lastSentOffset to current end>

Round:
<round>
```

发送后：

```text
lastSentOffset = currentGlobalEndOffset
dirtyOutput = false
lastDecisionAt = now
```

如果发生 compact 且 `lastSentOffset < baseOffset`，说明上次发送位置已经被压缩掉，此时 delta 退化为：

```text
[Output before this point was compacted.]
<current normalized text>
```

## 对话历史控制

`decisionHistory` 也需要成本上限，否则 tool call 历史会持续增长。

建议策略：

- 只保留最近 6 到 10 个 assistant/tool 消息。
- 旧 tool 结果合并进 `compactedPrefix` 或 `agentDecisionSummary`。
- Tool result 不记录大段输出，只记录结构化结果，例如 `wrote 3 bytes`、`user denied write`、`waited 2000ms`。
- `AskUser(sensitive=true)` 的用户输入继续只记录 `[REDACTED]`，不得进入 compact 摘要。

## 配置项

建议新增配置：

```jsonc
{
  "execution": {
    "pty_quiet_window_ms": 800,
    "pty_max_wait_after_output_ms": 5000,
    "pty_llm_compact_threshold_bytes": 131072,
    "pty_llm_compact_keep_bytes": 24576,
    "pty_decision_history_limit": 8,
    "pty_context_max_bytes": 32768
  }
}
```

兼容策略：

- 保留 `pty_min_interval_ms`，但语义改为 `lastDecisionAt` 的最小间隔保护。
- 废弃 `pty_min_bytes_threshold` 的“提前放行”语义。
- 旧配置文件缺少新字段时使用默认值并在保存配置时补齐。

## 状态机变化

主循环从：

```text
read output
shouldThrottle
call LLM
execute tool
```

改为：

```text
read output
normalize terminal text
append to compact buffer
mark dirty / update lastOutputAt / maybe compact
process child exit
if scheduler.shouldCall(now, childExited):
    build compact context
    call LLM
    execute tool
else:
    sleep 50-100ms
```

`Throttled` 状态可以保留给 TUI，但显示原因应更具体：

- `waiting_quiet_window`
- `waiting_next_eligible`
- `waiting_new_output`
- `waiting_min_interval`

## 落地步骤

1. 新增 `TerminalTextNormalizer`，覆盖 `\r`、退格、清行、基础光标移动和 SGR 忽略。
2. 新增 `PtyLlmContextBuffer`，支持 append、compact、context、delta。
3. 在 `PtyAgentLoop` 增加调度字段，替换 `shouldThrottle()`。
4. 修改 `callLlmForDecision()`，使用 compact context，不再调用完整 `textBuf.toPlainText()`。
5. 限制 `decisionHistory` 长度，旧决策合并为简短摘要。
6. 增加配置字段和默认值。
7. 更新 debug log，记录每轮 raw bytes、normalized bytes、compact 次数、context bytes、delta bytes、token usage。

## 验证方案

手动场景：

- `yes | head -n 100000`：不应触发 LLM 调用风暴。
- `curl -#` 或下载命令：`\r` 进度条不应在 LLM 上下文中堆叠。
- `apt`, `dnf`, `pacman` 等包管理器：ANSI 清行进度不应堆成重复历史。
- `sudo apt upgrade`：等待下载和安装输出稳定后再调用，遇到交互 prompt 能及时处理。
- 长编译命令：输出超过 compact 阈值后只发生少量 compact，后续继续 append。
- 静默命令：没有新输出时不应反复调用 LLM。
- `Wait` 连续返回：不应形成 Wait -> LLM -> Wait 的空转循环。

单元测试：

- `Downloading 1%\rDownloading 2%\rDownloading 3%\n` 归一化为单条最新进度。
- `ESC[2K\rProgress 10% ESC[2K\rProgress 20%` 归一化为最新进度。
- 普通多行输出不被误判为进度条。
- error 行在 compact 摘要中被保留。
- compact 后继续 append，不发生每次读取都裁剪。

日志验收：

- 每轮 LLM 请求的 `context bytes` 不超过 `pty_context_max_bytes`。
- 静默期间 `roundCount` 不增长。
- 刷屏期间 LLM 调用间隔受 `maxWaitAfterOutputMs` 限制。
- compact 只在超过阈值时发生，不随每轮 LLM 调用发生。
- 进度条刷新次数可见，但 prompt 中只有最新状态和刷新计数。

## 风险与处理

- compact 摘要遗漏早期错误：本地规则必须优先保留 error/prompt/password/permission 相关行。
- ANSI 控制序列截断：normalizer 需要保留未完成 escape 状态，下一次 feed 继续解析；compact 只作用于归一化文本，不直接截断原始 ANSI 流。
- 模型需要更早介入 prompt：静默窗口默认不宜过大，800ms 比较保守；进程退出和明确 prompt 检测可绕过静默窗口。
- 进度条被误判导致丢失信息：只有发生 `\r`、清行或同一物理行覆盖时才启用进度压缩；普通换行日志必须保留。
- 最终结果仍需要完整输出：LLM compact buffer 不替代 `PtyTextBuffer` 或 TUI 原始输出，完整结果路径保持独立。

## 预期效果

- 静默时 LLM 调用次数降为 0。
- 刷屏时调用频率由“按字节阈值提前触发”变为“静默后或硬上限后触发”。
- 单轮 prompt 大小固定在配置上限内，不随会话长度线性增长。
- `\r` 和 ANSI 进度条在 LLM 上下文中压缩为最新状态，不堆成重复历史。
- compact 只在阈值处批量发生，后续继续 append，避免滑动窗口式频繁搬移和缓存破坏。
