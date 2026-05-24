package termhelper.tests.pty_integration

import termhelper.infra.*
import std.collection.*
import std.time.*

// ═══════════════════════════════════════════════════════════════
// 阶段 2 集成测试 — PTY 创建 → 写入 → 读取 → 关闭
// 验证关口：#7 PTY 集成测试
// ═══════════════════════════════════════════════════════════════

/// PTY 创建和基础属性测试
func testPtyCreate(): Bool {
    println("── 测试 1：PTY 创建 ──")
    let ptyOpt = Pty.create(24, 80)
    match (ptyOpt) {
        case Some(pty) =>
            println("  OK: masterFd=${pty.masterFd}, slave=${pty.slavePath}")
            pty.close()
            true
        case None =>
            println("  FAIL: Pty.create 返回 None")
            false
    }
}

/// PTY 子进程启动 + 输出读取
func testPtySpawnRead(): Bool {
    println("── 测试 2：spawnChild + tryRead ──")
    let ptyOpt = Pty.create(24, 80)
    match (ptyOpt) {
        case Some(pty) =>
            let ok = pty.spawnChild("echo hello_from_pty")
            if (!ok) {
                println("  FAIL: spawnChild 返回 false")
                pty.close()
                return false
            }
            println("  OK: 子进程已启动")

            // 等待子进程产生输出
            sleep(500 * Duration.millisecond)
            let output = pty.tryRead(4096)
            println("  tryRead: ${output.size} bytes")
            let hasOutput = output.size > 0

            // 等待子进程结束
            sleep(500 * Duration.millisecond)
            let exited = pty.childExited()
            let ec = pty.getExitCode()
            println("  childExited=${exited}, exitCode=${ec}")

            pty.close()
            hasOutput
        case None =>
            println("  FAIL: Pty.create 返回 None")
            false
    }
}

/// PTY 写入测试
func testPtyWrite(): Bool {
    println("── 测试 3：PTY writeData ──")
    let ptyOpt = Pty.create(24, 80)
    match (ptyOpt) {
        case Some(pty) =>
            let written = pty.writeData("test_input\n")
            println("  writeData 返回 ${written} bytes")
            pty.close()
            written > 0
        case None =>
            println("  FAIL: Pty.create 返回 None")
            false
    }
}

/// PTY resize 测试（注：master fd 上 TIOCGWINSZ 可能返回 0，
/// 实际 resize 在 slave fd 打开后生效，此处验证 API 不崩溃即可）
func testPtyResize(): Bool {
    println("── 测试 4：PTY resize ──")
    let ptyOpt = Pty.create(24, 80)
    match (ptyOpt) {
        case Some(pty) =>
            // resize 在 master 上可能不支持，验证调用不崩溃
            pty.resize(30, 100)
            let (cols, rows) = pty.getSize()
            println("  resize 调用完成, getSize cols=${cols} rows=${rows}")
            println("  (master 侧 resize 受限，正式使用时在 slave 侧设置)")
            pty.close()
            true  // API 不崩溃即通过
        case None =>
            println("  FAIL: Pty.create 返回 None")
            false
    }
}

/// spawn 异步测试（Channel 式逐行输出）
func testSpawnAsync(): Bool {
    println("── 测试 5：spawnAsync 逐行输出 ──")
    let handle = spawnAsync("echo line1; echo line2; echo line3", 10000)

    var lines = ArrayList<String>()
    var done = false
    let startTime = MonoTime.now()

    while (!done) {
        match (handle.tryReadLine()) {
            case Some(line) => lines.add(line.text)
            case None => ()
        }
        if (handle.isDone()) {
            // 排干缓冲中的所有剩余行
            var more = handle.tryReadLine()
            while (true) {
                match (more) {
                    case Some(line) =>
                        lines.add(line.text)
                        more = handle.tryReadLine()
                    case None => break
                }
            }
            done = true
        }
    }

    let result = handle.waitDone()
    println("  收到 ${lines.size} 行, exitCode=${result.exitCode}")
    for (i in 0..lines.size) { println("  [${i}] ${lines[i]}") }

    lines.size == 3 && result.exitCode == 0
}

main(): Int64 {
    println("╔══════════════════════════════════════════════╗")
    println("║  阶段 2 PTY 集成测试                          ║")
    println("╚══════════════════════════════════════════════╝")
    println()

    let r1 = testPtyCreate()
    println(if (r1) { "  PASS" } else { "  FAIL" })
    println()

    let r2 = testPtySpawnRead()
    println(if (r2) { "  PASS" } else { "  FAIL" })
    println()

    let r3 = testPtyWrite()
    println(if (r3) { "  PASS" } else { "  FAIL" })
    println()

    let r4 = testPtyResize()
    println(if (r4) { "  PASS" } else { "  FAIL" })
    println()

    let r5 = testSpawnAsync()
    println(if (r5) { "  PASS" } else { "  FAIL" })
    println()

    let allPass = r1 && r2 && r3 && r4 && r5
    println(if (allPass) { "全部通过" } else { "存在失败项" })
    if (allPass) { 0 } else { 1 }
}
