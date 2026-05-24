package termhelper.tests.concurrency_verify

// ═══════════════════════════════════════════════════════════════
// 阶段 1.5：并发原语验证
// 验证 spawn / Future / Mutex / synchronized / Atomic
// ═══════════════════════════════════════════════════════════════

import std.sync.*
import std.collection.*

func verifySpawn(): Bool {
    println("── 测试 1：spawn + Future.get() ──")
    let future = spawn { =>
        sleep(100 * Duration.millisecond)
        42
    }
    let result = future.get()
    println("  Future.get() = ${result} (预期 42)")
    result == 42
}

func verifyMutex(): Bool {
    println("── 测试 2：Mutex + synchronized ──")
    let mtx = Mutex()
    var acquired: Bool = false

    synchronized(mtx) {
        acquired = true
        println("  synchronized 块进入成功")
    }
    println("  synchronized 块退出成功")

    let gotLock = mtx.tryLock()
    if (gotLock) {
        mtx.unlock()
    }
    println("  tryLock 返回: ${gotLock}")
    acquired && gotLock
}

func verifyAtomic(): Bool {
    println("── 测试 3：Atomic 原子操作 ──")
    let atomic = AtomicInt64(0)
    let iterations: Int64 = 1000
    let numThreads: Int64 = 4
    let counter = SyncCounter(numThreads)

    for (i in 0..numThreads) {
        spawn { =>
            for (j in 0..iterations) {
                atomic.fetchAdd(1)
            }
            counter.dec()
        }
    }

    counter.waitUntilZero()
    let result = atomic.load()
    let expected = iterations * numThreads
    println("  Atomic 累加结果: ${result} (预期 ${expected})")
    result == expected
}

func verifySyncCounter(): Bool {
    println("── 测试 4：SyncCounter 线程协调 ──")
    let numThreads: Int64 = 5
    let counter = SyncCounter(numThreads)
    let completed = AtomicInt64(0)

    for (i in 0..numThreads) {
        spawn { =>
            sleep(50 * Duration.millisecond)
            completed.fetchAdd(1)
            counter.dec()
        }
    }

    counter.waitUntilZero()
    let c = completed.load()
    println("  SyncCounter 完成计数: ${c} (预期 ${numThreads})")
    c == numThreads
}

public func verify(): Bool {
    println("╔══════════════════════════════════════════════╗")
    println("║  1.5 并发原语验证                             ║")
    println("╚══════════════════════════════════════════════╝")
    println()

    let r1 = verifySpawn()
    println(if (r1) { "  PASS" } else { "  FAIL" })
    println()

    let r2 = verifyMutex()
    println(if (r2) { "  PASS" } else { "  FAIL" })
    println()

    let r3 = verifyAtomic()
    println(if (r3) { "  PASS" } else { "  FAIL" })
    println()

    let r4 = verifySyncCounter()
    println(if (r4) { "  PASS" } else { "  FAIL" })
    println()

    let allPass = r1 && r2 && r3 && r4
    println(if (allPass) { "全部通过" } else { "存在失败项" })
    allPass
}

main(): Int64 {
    if (verify()) { 0 } else { 1 }
}
