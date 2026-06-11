package termhelper.util

import termhelper.types.*

@Test
func environmentContextSummaryUsesStableSortedFactOrder(): Unit {
    let ctx = EnvironmentContext()
    ctx.version = 4
    ctx.lastUpdated = 100
    ctx.facts.add("z.fact", fact("Z fact", "test", 20))
    ctx.facts.add("a.fact", fact("A fact", "test", 10))

    let summary = environmentContextSummary(ctx)

    @Expect(summary.contains("Known environment facts:\n- id=a.fact: A fact"))
    @Expect(testStrFind(summary, "id=a.fact") < testStrFind(summary, "id=z.fact"))
    @Expect(summary.contains("Recently updated facts:"))
    @Expect(summary.contains("Current shell (dynamic, not persisted):"))
}

@Test
func environmentContextSummaryShowsNoneForEmptyFacts(): Unit {
    let ctx = EnvironmentContext()

    let summary = environmentContextSummary(ctx)

    @Expect(summary.contains("Known environment facts:\n- none"))
}

func fact(text: String, source: String, lastVerified: Int64): EnvironmentFact {
    let f = EnvironmentFact()
    f.text = text
    f.source = source
    f.lastVerified = lastVerified
    f
}

func testStrFind(haystack: String, needle: String): Int64 {
    if (needle.size == 0) {
        return 0
    }
    if (needle.size > haystack.size) {
        return -1
    }
    for (i in 0..(haystack.size - needle.size + 1)) {
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
    }
    -1
}
