package termhelper.adapters

import std.collection.ArrayList

// ═══════════════════════════════════════════════════════════════
// SSE (Server-Sent Events) 流式解析器
// 支持 OpenAI / Anthropic / Google 三种 SSE 格式
// ═══════════════════════════════════════════════════════════════

/// 解析出的单个 SSE 事件
public struct SseEvent {
    public let event: String // event 类型（空 = "message"）
    public let data: String // data 字段（多行以 \n 连接）
    public let id: String // 事件 id

    public init(event: String, data: String, id: String) {
        this.event = event
        this.data = data
        this.id = id
    }
}

/// SSE 解析器（字节 → 事件）
/// 用法：逐块 feedData → tryGetEvent 轮询 → 直到流结束
public class SseParser {
    // 内部行缓冲区（未完成的行，等待 \n）
    private var lineBuf: ArrayList<UInt8>

    // 当前事件的字段累积
    private var currentEvent: String
    private var currentData: ArrayList<String>
    private var currentId: String

    // 已完成的事件队列
    private var events: ArrayList<SseEvent>

    // 是否收到 [DONE] 标记
    private var _done: Bool

    public init() {
        this.lineBuf = ArrayList<UInt8>()
        this.currentEvent = ""
        this.currentData = ArrayList<String>()
        this.currentId = ""
        this.events = ArrayList<SseEvent>()
        this._done = false
    }

    /// 喂入一批字节数据
    public func feedData(data: Array<UInt8>): Unit {
        for (b in data) {
            feedByte(b)
        }
    }

    /// 喂入一个字节
    public func feedByte(b: UInt8): Unit {
        if (b == b'\n') {
            // 行结束，处理完成的行
            processLine()
        } else if (b != b'\r') {
            // 跳过 \r，其他字节加入行缓冲
            lineBuf.add(b)
        }
    }

    /// 尝试获取下一个已完成的事件（非阻塞）
    public func tryGetEvent(): ?SseEvent {
        if (events.size > 0) {
            let evt = events[0]
            events.remove(at: 0)
            Some(evt)
        } else {
            None
        }
    }

    /// 是否已收到流结束标记 [DONE]
    public func isDone(): Bool {
        _done
    }

    // ── 内部 ──

    /// 将行缓冲区转为 String
    private func lineString(): String {
        String.fromUtf8(lineBuf.toArray())
    }

    /// 处理一个完整的行
    private func processLine(): Unit {
        let line = lineString()
        lineBuf.clear()

        if (line.size == 0) {
            // 空行 = 事件边界 → 分发事件
            dispatchEvent()
            return
        }

        // 注释行（以 : 开头），忽略
        if (line.startsWith(":")) {
            return
        }

        // 解析字段
        if (line.startsWith("data:")) {
            let v = stripPrefix(line, "data:")
            let trimmed = v.trimAscii()
            currentData.add(trimmed)
            // 检测 [DONE] 标记
            if (trimmed == "[DONE]") {
                _done = true
            }
        } else if (line.startsWith("event:")) {
            let v = stripPrefix(line, "event:")
            currentEvent = v.trimAscii()
        } else if (line.startsWith("id:")) {
            let v = stripPrefix(line, "id:")
            currentId = v.trimAscii()
        }
        // 忽略不识别的字段（retry: 等）
    }

    /// 当前事件完成，加入队列并重置
    private func dispatchEvent(): Unit {
        // 忽略没有 data 的边界事件（如 Anthropic ping 前的空行）
        // 但保留 event 字段单独的事件（如 content_block_start 可能没有 data）
        let dataStr = joinStrings(currentData, "\n")
        if (dataStr.size == 0 && currentEvent.size == 0) {
            currentData.clear()
            return
        }

        let evt = SseEvent(currentEvent, dataStr, currentId)
        events.add(evt)

        // 重置字段
        currentEvent = ""
        currentData.clear()
        currentId = ""
    }

    private func joinStrings(strings: ArrayList<String>, sep: String): String {
        var result = ""
        for (i in 0..strings.size) {
            if (i > 0) {
                result += sep
            }
            result += strings[i]
        }
        result
    }
}
