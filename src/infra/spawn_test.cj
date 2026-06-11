package termhelper.infra

import std.env.*

@Test
func spawnRunsCommandThroughShell(): Unit {
    let result = spawnCommandWithTimeout("printf 'hi' | tr h H", 3000)

    @Expect(result.exitCode, 0)
    @Expect(result.stdout, "Hi")
    @Expect(result.stderr, "")
}

@Test
func spawnInheritsParentEnvironment(): Unit {
    setVariable("TERMHELPER_SPAWN_TEST", "env-ok")
    let result = spawnCommandWithTimeout("printf '%s' \"$TERMHELPER_SPAWN_TEST\"", 3000)
    removeVariable("TERMHELPER_SPAWN_TEST")

    @Expect(result.exitCode, 0)
    @Expect(result.stdout, "env-ok")
}

@Test
func spawnSeparatesStdoutAndStderr(): Unit {
    let result = spawnCommandWithTimeout("printf out; printf err >&2", 3000)

    @Expect(result.exitCode, 0)
    @Expect(result.stdout, "out")
    @Expect(result.stderr, "err")
}

@Test
func spawnTimeoutTerminatesLongRunningProcess(): Unit {
    let result = spawnCommandWithTimeout("sleep 5", 50)

    @Expect(result.exitCode, -1)
}
