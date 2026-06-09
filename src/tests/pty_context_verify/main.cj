package termhelper.tests.pty_context_verify

import termhelper.infra.*

func expectContains(name: String, text: String, pattern: String): Bool {
    if (text.contains(pattern)) {
        println("  OK: ${name}")
        true
    } else {
        println("  FAIL: ${name}, missing '${pattern}' in: ${text}")
        false
    }
}

func expectNotContains(name: String, text: String, pattern: String): Bool {
    if (!text.contains(pattern)) {
        println("  OK: ${name}")
        true
    } else {
        println("  FAIL: ${name}, unexpected '${pattern}' in: ${text}")
        false
    }
}

func testCarriageReturnProgress(): Bool {
    println("── 测试 1：CR 进度条归一化 ──")
    let normalizer = TerminalTextNormalizer()
    let out = normalizer.feed("Downloading 10%\rDownloading 20%\rDownloading 30%\nDone\n")
    var ok = expectContains("latest progress kept", out, "latest: Downloading 30%")
    ok = expectContains("following line kept", out, "Done") && ok
    ok = expectNotContains("old progress not repeated", out, "Downloading 10%\nDownloading 20%") && ok
    ok
}

func testAnsiClearProgress(): Bool {
    println("── 测试 2：ANSI 清行进度条归一化 ──")
    let normalizer = TerminalTextNormalizer()
    let out = normalizer.feed("\u{1b}[2K\rProgress 10%\u{1b}[2K\rProgress 20%\n")
    var ok = expectContains("latest ansi progress kept", out, "latest: Progress 20%")
    ok = expectNotContains("ansi progress not stacked", out, "Progress 10%\nProgress 20%") && ok
    ok
}

func testAnsiZeroGProgress(): Bool {
    println("── 测试 3：ESC[0G 行首刷新归一化 ──")
    let normalizer = TerminalTextNormalizer()
    let out = normalizer.feed("Step 1\u{1b}[0GStep 2\n")
    var ok = expectContains("zero G moves to line start", out, "latest: Step 2")
    ok = expectNotContains("old zero G text not stacked", out, "Step 1\nStep 2") && ok
    ok
}

func testCompactBuffer(): Bool {
    println("── 测试 4：compact 后继续 append ──")
    let buf = PtyLlmContextBuffer(64, 24, 128)
    let _ = buf.append("line one\nline two\nerror: important failure\n")
    let _ = buf.append("line three\nline four\nline five\nline six\n")
    let snap = buf.snapshot()
    var ok = buf.getCompactCount() > 0
    if (ok) { println("  OK: compact triggered") } else { println("  FAIL: compact did not trigger") }
    ok = expectContains("important line retained", snap.checkpoint, "error: important failure") && ok
    ok
}

func testOpenPromptPreview(): Bool {
    println("── 测试 5：无换行 prompt 进入 snapshot ──")
    let buf = PtyLlmContextBuffer(1024, 256, 512)
    let _ = buf.append("[sudo] password for user: ")
    let snap = buf.snapshot()
    expectContains("open prompt visible", snap.delta, "password for user:")
}

main(): Int64 {
    var ok = true
    ok = testCarriageReturnProgress() && ok
    ok = testAnsiClearProgress() && ok
    ok = testAnsiZeroGProgress() && ok
    ok = testCompactBuffer() && ok
    ok = testOpenPromptPreview() && ok
    if (ok) {
        println("PTY context verify: PASS")
        return 0
    }
    println("PTY context verify: FAIL")
    1
}
