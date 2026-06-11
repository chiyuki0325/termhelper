package termhelper.adapters

@Test
func sseParserDispatchesEventAfterBlankLineAcrossChunks(): Unit {
    let parser = SseParser()

    parser.feedData("event: message\nid: 42\ndata: {\"delta\":\"he".toArray())
    @Expect(parser.tryGetEvent().isNone())

    parser.feedData("llo\"}\n\n".toArray())
    let event = parser.tryGetEvent().getOrThrow()

    @Expect(event.event, "message")
    @Expect(event.id, "42")
    @Expect(event.data, "{\"delta\":\"hello\"}")
    @Expect(parser.tryGetEvent().isNone())
}

@Test
func sseParserJoinsMultilineDataAndIgnoresComments(): Unit {
    let parser = SseParser()

    parser.feedData(": keepalive\ndata: first\ndata: second\n\n".toArray())
    let event = parser.tryGetEvent().getOrThrow()

    @Expect(event.event, "")
    @Expect(event.data, "first\nsecond")
}

@Test
func sseParserHandlesCrLfAndDoneMarker(): Unit {
    let parser = SseParser()

    parser.feedData("event: done\r\ndata: [DONE]\r\n\r\n".toArray())
    let event = parser.tryGetEvent().getOrThrow()

    @Expect(parser.isDone(), true)
    @Expect(event.event, "done")
    @Expect(event.data, "[DONE]")
}

@Test
func sseParserIgnoresEmptyBoundariesWithoutDataOrEvent(): Unit {
    let parser = SseParser()

    parser.feedData("\n\n".toArray())

    @Expect(parser.tryGetEvent().isNone())
}
