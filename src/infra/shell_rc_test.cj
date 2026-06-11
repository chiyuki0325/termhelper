package termhelper.infra

import std.fs.*

@Test
func generateAliasUsesShellSpecificSyntax(): Unit {
    @Expect(generateAlias("bash"), "alias '??'='termhelper'")
    @Expect(generateAlias("zsh"), "alias '??'='termhelper'")
    @Expect(generateAlias("fish"), "alias '??' termhelper")
    @Expect(generateAlias("nushell"), "def \"??\" [ ...args ] { termhelper ...$args }")
}

@Test
func installWritesMarkedBlockAndIsIdempotent(): Unit {
    let dir = "/tmp/termhelper-shell-rc-install"
    let path = "${dir}/.bashrc"
    cleanupShellRcTestDir(dir)

    @Expect(install(path, "bash"), true)
    @Expect(install(path, "bash"), false)

    let content = readFileString(path)
    @Expect(strContains(content, "# >>> termhelper >>>"), true)
    @Expect(strContains(content, "alias '??'='termhelper'"), true)
    @Expect(countSubstring(content, "# >>> termhelper >>>"), 1)

    cleanupShellRcTestDir(dir)
}

@Test
func uninstallRemovesOnlyTermhelperBlock(): Unit {
    let dir = "/tmp/termhelper-shell-rc-uninstall"
    let path = "${dir}/.zshrc"
    cleanupShellRcTestDir(dir)
    writeFileString(path, "before\n")
    install(path, "zsh")
    writeFileString(path, readFileString(path) + "after\n")

    @Expect(uninstall(path), true)

    @Expect(readFileString(path), "before\n\nafter\n")
    cleanupShellRcTestDir(dir)
}

@Test
func uninstallRejectsCorruptMarker(): Unit {
    let dir = "/tmp/termhelper-shell-rc-corrupt"
    let path = "${dir}/.bashrc"
    cleanupShellRcTestDir(dir)
    writeFileString(path, "before\n# >>> termhelper >>>\nalias '??'='termhelper'\n")

    @Expect(uninstall(path), false)
    @Expect(strContains(readFileString(path), "# >>> termhelper >>>"), true)

    cleanupShellRcTestDir(dir)
}

func cleanupShellRcTestDir(dir: String): Unit {
    let path = Path(dir)
    if (exists(path)) {
        remove(path, recursive: true)
    }
}

func countSubstring(text: String, needle: String): Int64 {
    var count: Int64 = 0
    var start: Int64 = 0
    while (start < text.size) {
        let idx = strFindFrom(text, needle, start)
        if (idx < 0) {
            return count
        }
        count += 1
        start = idx + needle.size
    }
    count
}

func strFindFrom(haystack: String, needle: String, start: Int64): Int64 {
    if (needle.size == 0) {
        return start
    }
    if (needle.size > haystack.size || start >= haystack.size) {
        return -1
    }
    var i = start
    while (i <= haystack.size - needle.size) {
        var found = true
        for (j in 0..needle.size) {
            if (haystack[i + j] != needle[j]) {
                found = false
                break
            }
        }
        if (found) {
            return i
        }
        i += 1
    }
    -1
}
