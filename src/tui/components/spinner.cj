package termhelper.tui.components

public class Spinner {
    private let frames: Array<String>
    private var index: Int64

    public init() {
        this.frames = ["|", "/", "-", "\\"]
        this.index = 0
    }

    public func tick(): String {
        let frame = frames[index % frames.size]
        index = index + 1
        frame
    }
}

public func spinnerFrame(tick: Int64): String {
    let frames = ["|", "/", "-", "\\"]
    frames[tick % frames.size]
}
