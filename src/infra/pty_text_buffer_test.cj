package termhelper.infra

@Test
func ptyTextBufferStripsAnsiEscapes(): Unit {
    let esc = String(Rune(27))
    let buffer = PtyTextBuffer()

    buffer.append("plain ${esc}[31mred${esc}[0m text")

    @Expect(buffer.toPlainText(), "plain red text")
}

@Test
func terminalTextNormalizerCompactsCarriageReturnProgress(): Unit {
    let normalizer = TerminalTextNormalizer()

    let output = normalizer.feed("Downloading 10%\rDownloading 90%\n")

    @Expect(output, "[progress updated 1 times, latest: Downloading 90%]\n")
}

@Test
func terminalTextNormalizerHandlesBackspaceOverwrite(): Unit {
    let normalizer = TerminalTextNormalizer()

    let output = normalizer.feed("ab\bC\n")

    @Expect(output, "[progress updated 1 times, latest: aC]\n")
}

@Test
func terminalTextNormalizerPreservesUtf8Text(): Unit {
    let normalizer = TerminalTextNormalizer()

    let output = normalizer.feed("中文输出\n")

    @Expect(output, "中文输出\n")
}

@Test
func safeUtf8ReplacesTruncatedSequence(): Unit {
    let text = safeUtf8([0xE4, 0xB8])
    let replacementTwice = String.fromUtf8([0xEF, 0xBF, 0xBD, 0xEF, 0xBF, 0xBD])

    @Expect(text, replacementTwice)
}
