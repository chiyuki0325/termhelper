package termhelper.infra

import std.collection.*

@Test
func terminalBufferHandlesCarriageReturnOverwrite(): Unit {
    let buffer = TerminalBuffer(1, 5)

    buffer.processString("abc\rXY")

    @Expect(rowText(buffer, 0), "XYc  ")
}

@Test
func terminalBufferMovesCursorAndOverwritesText(): Unit {
    let buffer = TerminalBuffer(1, 6)
    let esc = String(Rune(27))

    buffer.processString("hello${esc}[2DXY")

    @Expect(rowText(buffer, 0), "helXY ")
}

@Test
func terminalBufferErasesLineFromCursor(): Unit {
    let buffer = TerminalBuffer(1, 6)
    let esc = String(Rune(27))

    buffer.processString("hello${esc}[3D${esc}[K")

    @Expect(rowText(buffer, 0), "he    ")
}

@Test
func terminalBufferClearsScreenAndHomesCursor(): Unit {
    let buffer = TerminalBuffer(2, 5)
    let esc = String(Rune(27))

    buffer.processString("hello\nworld${esc}[2J")

    @Expect(rowText(buffer, 0), "     ")
    @Expect(rowText(buffer, 1), "     ")
    @Expect(buffer.cursor.row, 0)
    @Expect(buffer.cursor.col, 0)
}

@Test
func terminalBufferAppliesAndResetsSgrAttributes(): Unit {
    let buffer = TerminalBuffer(1, 4)
    let esc = String(Rune(27))

    buffer.processString("${esc}[1;31mA${esc}[0mB")
    let row = buffer.getRow(0)

    @Expect(row[0].char, r'A')
    @Expect(row[0].attrs.bold, true)
    @Expect(row[0].fg.idx, 1)
    @Expect(row[1].char, r'B')
    @Expect(row[1].attrs.bold, false)
    @Expect(row[1].fg.idx, -1)
}

@Test
func terminalBufferScrollsIntoScrollback(): Unit {
    let buffer = TerminalBuffer(2, 6)

    buffer.processString("one\ntwo\nthree")

    @Expect(buffer.scrollbackSize(), 1)
    @Expect(rowText(buffer.getScrollbackRow(0)), "one   ")
    @Expect(rowText(buffer, 0), "two   ")
    @Expect(rowText(buffer, 1), "three ")
}

@Test
func terminalBufferStoresCjkAsDoubleWidthCell(): Unit {
    let buffer = TerminalBuffer(1, 6)

    buffer.processString("a中b")
    let row = buffer.getRow(0)

    @Expect(row[0].char, r'a')
    @Expect(row[1].char, r' ')
    @Expect(row[2].char, r'中')
    @Expect(row[3].char, Rune(0))
    @Expect(row[4].char, r'b')
    @Expect(buffer.cursor.col, 5)
}

func rowText(buffer: TerminalBuffer, row: Int64): String {
    rowText(buffer.getRow(row))
}

func rowText(row: ArrayList<Cell>): String {
    var text = ""
    for (cell in row) {
        if (cell.char != Rune(0)) {
            text += String(cell.char)
        }
    }
    text
}
