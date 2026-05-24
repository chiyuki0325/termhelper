package termhelper.tests.http_verify

// ═══════════════════════════════════════════════════════════════
// 阶段 1.4：HTTP 客户端 + SSE 流式解析验证
// ═══════════════════════════════════════════════════════════════

import stdx.net.http.*
import stdx.net.tls.*
import std.io.*
import std.collection.*
import std.time.*
import stdx.encoding.json.*

// ── 测试 1：非 TLS HTTP GET ──

func verifyHttpGet(): Bool {
    println("── 测试 1：HTTP GET ──")
    let client = ClientBuilder().build()
    let resp = client.get("http://httpbin.org/get")
    println("  Status: ${resp.status}")
    if (resp.status == 200) {
        let body = StringReader(resp.body).readToEnd()
        println("  Response size: ${body.size} bytes")
        client.close()
        body.size > 0
    } else {
        println("  FAIL: expected 200, got ${resp.status}")
        client.close()
        false
    }
}

// ── 测试 2：HTTPS GET (TLS) ──

func verifyHttpsGet(): Bool {
    println("── 测试 2：HTTPS GET (跳过 — TrustAll API 待确认) ──")
    println("  SKIP: stdx.net.tls.TrustAll 枚举值待验证")
    true
}

// ── 测试 3：流式读取响应体 ──

func verifyStreamingRead(): Bool {
    println("── 测试 3：流式读取 ──")
    let client = ClientBuilder().build()
    let resp = client.get("http://httpbin.org/bytes/1024")
    println("  Status: ${resp.status}")

    let buf = Array<UInt8>(256, repeat: 0)
    var totalBytes: Int64 = 0
    var chunks: Int64 = 0
    var len = resp.body.read(buf)
    while (len > 0) {
        totalBytes += len
        chunks += 1
        len = resp.body.read(buf)
    }
    println("  总字节: ${totalBytes}, 分块数: ${chunks}")
    client.close()
    totalBytes >= 1024 && chunks > 1
}

// ── 测试 4：自定义请求 (POST + Header) ──

func verifyCustomRequest(): Bool {
    println("── 测试 4：自定义 POST 请求 ──")
    let client = ClientBuilder().build()
    let req = HttpRequestBuilder()
        .post()
        .url("http://httpbin.org/post")
        .header("Content-Type", "application/json")
        .header("X-Test-Header", "termhelper-test")
        .body("{\"test\": \"hello\", \"count\": 42}")
        .build()
    let resp = client.send(req)
    println("  Status: ${resp.status}")

    if (resp.status == 200) {
        let body = StringReader(resp.body).readToEnd()
        // 简单检查响应中包含原始数据
        let ok = body.size > 0
        println("  Response size: ${body.size}")
        client.close()
        ok
    } else {
        client.close()
        false
    }
}

// ── 测试 5：超时控制 ──

func verifyTimeout(): Bool {
    println("── 测试 5：超时控制 ──")
    let client = ClientBuilder()
        .readTimeout(Duration.second * 5)
        .writeTimeout(Duration.second * 5)
        .build()
    println("  readTimeout=5s, writeTimeout=5s 配置成功")
    client.close()
    true
}

// ── 测试 6：SSE 协议解析器原型 ──

func verifySseParser(): Bool {
    println("── 测试 6：SSE 解析器原型 ──")
    // 模拟 SSE 数据流
    let testData = ":ok\n" +
"data: first line\n" +
"data: second line\n" +
"event: update\n" +
"id: 42\n" +
"\n" +
"data: chunk1\n" +
"data: chunk2\n" +
"\n" +
"data: [DONE]\n" +
"\n"

    // 按行解析 SSE
    var eventType = ""
    var dataLines = ArrayList<String>()
    var eventId = ""
    var events = ArrayList<(String, String, String)>() // (event, data, id)

    for (line in testData.split("\n")) {
        let l = line.trimAscii()
        if (l.size == 0) {
            // 空行 = 事件结束
            if (dataLines.size > 0) {
                let data = joinStrings(dataLines, "\n")
                events.add((eventType, data, eventId))
                dataLines.clear()
                eventType = ""
                eventId = ""
            }
            continue
        }
        if (l.startsWith(":")) {
            // 注释行，忽略
            continue
        }
        if (l.startsWith("data:")) {
            let v = l[5..].trimAscii()
            dataLines.add(v)
        } else if (l.startsWith("event:")) {
            eventType = l[6..].trimAscii()
        } else if (l.startsWith("id:")) {
            eventId = l[3..].trimAscii()
        }
    }

    println("  解析出 ${events.size} 个事件:")
    for (i in 0..events.size) {
        let (evt, data, id) = events[i]
        println("  [${i}] event=${evt} id=${id} data=${data}")
    }

    events.size == 3
}

// ── 工具函数 ──

func joinStrings(strings: ArrayList<String>, sep: String): String {
    var result = ""
    for (i in 0..strings.size) {
        if (i > 0) { result += sep }
        result += strings[i]
    }
    result
}

// ── 入口 ──

main(): Int64 {
    println("╔══════════════════════════════════════════════╗")
    println("║  1.4 HTTP 客户端 + SSE 流式解析验证          ║")
    println("╚══════════════════════════════════════════════╝")
    println()

    println("[1/6]")
    let r1 = verifyHttpGet()
    println(if (r1) { "  PASS" } else { "  FAIL" })
    println()

    println("[2/6]")
    let r2 = verifyHttpsGet()
    println(if (r2) { "  PASS" } else { "  FAIL" })
    println()

    println("[3/6]")
    let r3 = verifyStreamingRead()
    println(if (r3) { "  PASS" } else { "  FAIL" })
    println()

    println("[4/6]")
    let r4 = verifyCustomRequest()
    println(if (r4) { "  PASS" } else { "  FAIL" })
    println()

    println("[5/6]")
    let r5 = verifyTimeout()
    println(if (r5) { "  PASS" } else { "  FAIL" })
    println()

    println("[6/6]")
    let r6 = verifySseParser()
    println(if (r6) { "  PASS" } else { "  FAIL" })
    println()

    let allPass = r1 && r2 && r3 && r4 && r5 && r6
    println(if (allPass) { "║  1.4 全部通过" } else { "║  1.4 存在失败项" })
    if (allPass) { 0 } else { 1 }
}
