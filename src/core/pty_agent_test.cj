package termhelper.core

import termhelper.types.*

@Test
func parsePtyToolParsesWriteAskUserWaitExitAndInterrupt(): Unit {
    match (parsePtyTool("Write", "{\"content\":\"y\\n\",\"reason\":\"confirm prompt\"}")) {
        case Some(PtyTool.Write(content, reason)) =>
            @Expect(content, "y\n")
            @Expect(reason, "confirm prompt")
        case _ => @Fail("expected Write tool")
    }

    match (parsePtyTool("AskUser", "{\"question\":\"Password?\",\"sensitive\":true}")) {
        case Some(PtyTool.AskUser(question, sensitive)) =>
            @Expect(question, "Password?")
            @Expect(sensitive, true)
        case _ => @Fail("expected AskUser tool")
    }

    match (parsePtyTool("Wait", "{\"seconds\":3}")) {
        case Some(PtyTool.Wait(seconds)) => @Expect(seconds, 3)
        case _ => @Fail("expected Wait tool")
    }

    match (parsePtyTool("Exit", "{\"summary\":\"done\"}")) {
        case Some(PtyTool.Exit(summary)) => @Expect(summary, "done")
        case _ => @Fail("expected Exit tool")
    }

    match (parsePtyTool("Interrupt", "{\"reason\":\"stuck\"}")) {
        case Some(PtyTool.Interrupt(reason)) => @Expect(reason, "stuck")
        case _ => @Fail("expected Interrupt tool")
    }
}

@Test
func parsePtyToolRejectsUnknownToolName(): Unit {
    @Expect(parsePtyTool("Unknown", "{}").isNone())
}

@Test
func extractJsonStringUnescapesCommonEscapes(): Unit {
    let json = "{\"content\":\"line1\\nline2\\t\\\"quoted\\\"\\\\path\",\"reason\":\"ok\"}"

    @Expect(extractJsonString(json, "content"), "line1\nline2\t\"quoted\"\\path")
    @Expect(extractJsonString(json, "reason"), "ok")
    @Expect(extractJsonString(json, "missing"), "")
}

@Test
func extractWaitSecondsSupportsSecondsMillisecondsAndDefault(): Unit {
    @Expect(extractWaitSeconds("{\"seconds\":7}"), 7)
    @Expect(extractWaitSeconds("{\"seconds\":\"4\"}"), 4)
    @Expect(extractWaitSeconds("{\"milliseconds\":2500}"), 3)
    @Expect(extractWaitSeconds("{\"milliseconds\":0}"), 1)
    @Expect(extractWaitSeconds("{}"), 1)
}

@Test
func unescapeJsonHandlesKnownEscapesAndPassesThroughUnknownEscapes(): Unit {
    @Expect(unescapeJson("a\\nb\\tc\\rd\\\"e\\\\f\\/g"), "a\nb\tc\rd\"e\\f/g")
}
