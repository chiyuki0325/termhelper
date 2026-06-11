package termhelper.core

import termhelper.types.*
import std.collection.*

@Test
func applyFactEditsAppliesAddUpdateDeleteAndTimestamps(): Unit {
    let ctx = EnvironmentContext()
    ctx.version = 4
    ctx.lastUpdated = 10
    ctx.facts.add("tool.git", testFact("git is missing", "initial", 1))
    ctx.facts.add("old.fact", testFact("remove me", "initial", 2))

    let edits = ArrayList<FactEdit>()
    edits.add(testEdit("update", "tool.git", "git is missing", "git exists at /usr/bin/git", "command -v git"))
    edits.add(testEdit("add", "tool.rg", "", "ripgrep exists at /usr/bin/rg", "command -v rg"))
    edits.add(testEdit("delete", "old.fact", "remove me", "", "cleanup"))

    let allowedSources = ArrayList<String>()
    allowedSources.add("command -v git")
    allowedSources.add("command -v rg")
    allowedSources.add("cleanup")

    let updated = ContextManager().applyFactEdits(ctx, edits, allowedSources)

    @Expect(ctx.facts.contains("old.fact"), true)
    @Expect(updated.facts.contains("old.fact"), false)
    @Expect(updated.facts.get("tool.git").getOrThrow().text, "git exists at /usr/bin/git")
    @Expect(updated.facts.get("tool.rg").getOrThrow().text, "ripgrep exists at /usr/bin/rg")
    @Expect(updated.facts.get("tool.git").getOrThrow().source, "command -v git")
    @Expect(updated.lastUpdated > ctx.lastUpdated)
    @Expect(updated.facts.get("tool.git").getOrThrow().lastVerified, updated.lastUpdated)
    @Expect(updated.facts.get("tool.rg").getOrThrow().lastVerified, updated.lastUpdated)
}

@Test
func applyFactEditsRejectsMismatchedOldTextInvalidIdAndSource(): Unit {
    let ctx = EnvironmentContext()
    ctx.version = 4
    ctx.lastUpdated = 20
    ctx.facts.add("tool.git", testFact("git exists", "initial", 3))
    ctx.facts.add("old.fact", testFact("keep me", "initial", 4))

    let edits = ArrayList<FactEdit>()
    edits.add(testEdit("update", "tool.git", "wrong old text", "updated", "command -v git"))
    edits.add(testEdit("delete", "old.fact", "wrong old text", "", "cleanup"))
    edits.add(testEdit("add", "bad id with spaces", "", "bad id", "command -v bad"))
    edits.add(testEdit("add", "tool.rg", "", "ripgrep exists", "disallowed source"))

    let allowedSources = ArrayList<String>()
    allowedSources.add("command -v git")
    allowedSources.add("command -v bad")
    allowedSources.add("cleanup")

    let updated = ContextManager().applyFactEdits(ctx, edits, allowedSources)

    @Expect(updated.lastUpdated, ctx.lastUpdated)
    @Expect(updated.facts.get("tool.git").getOrThrow().text, "git exists")
    @Expect(updated.facts.get("old.fact").getOrThrow().text, "keep me")
    @Expect(updated.facts.contains("bad id with spaces"), false)
    @Expect(updated.facts.contains("tool.rg"), false)
    @Expect(updated.facts.get("tool.git").getOrThrow().lastVerified, 3)
}

func testFact(text: String, source: String, lastVerified: Int64): EnvironmentFact {
    let fact = EnvironmentFact()
    fact.text = text
    fact.source = source
    fact.lastVerified = lastVerified
    fact
}

func testEdit(op: String, id: String, oldText: String, newText: String, source: String): FactEdit {
    let edit = FactEdit()
    edit.op = op
    edit.id = id
    edit.oldText = oldText
    edit.newText = newText
    edit.source = source
    edit
}
