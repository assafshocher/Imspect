import AppKit

final class ImageListTableView: NSTableView {
    var onDelete: ((Int) -> Void)?
    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 51 || event.keyCode == 117), selectedRow >= 0 {
            onDelete?(selectedRow)
            return
        }
        super.keyDown(with: event)
    }
}

final class ChannelSlider: NSSlider {
    var onBeginDrag: (() -> Void)?
    var onEndDrag: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        onBeginDrag?()
        super.mouseDown(with: event)
        onEndDrag?()
    }
}

final class WorkCancellation {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}
