import AppKit
import SwiftUI

/// Makes a shelf item draggable as a real file and reports when it was
/// dropped somewhere, so the shelf can let go of it. Double-click opens it.
struct FileDragSourceView: NSViewRepresentable {
    let url: URL
    let onDraggedOut: () -> Void

    func makeNSView(context: Context) -> DragNSView {
        DragNSView()
    }

    func updateNSView(_ view: DragNSView, context: Context) {
        view.url = url
        view.onDraggedOut = onDraggedOut
    }

    final class DragNSView: NSView {
        var url: URL?
        var onDraggedOut: (() -> Void)?
        private var mouseDownEvent: NSEvent?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            mouseDownEvent = event
            if event.clickCount == 2, let url { NSWorkspace.shared.open(url) }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let url, let start = mouseDownEvent else { return }
            let a = start.locationInWindow, b = event.locationInWindow
            guard hypot(b.x - a.x, b.y - a.y) > 4 else { return }
            mouseDownEvent = nil

            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            item.setDraggingFrame(NSRect(x: bounds.midX - 26, y: bounds.midY - 20, width: 52, height: 52), contents: icon)
            let source = DragSource(onDraggedOut: onDraggedOut)
            beginDraggingSession(with: [item], event: event, source: source)
        }
    }

    /// Kept alive by itself until the session ends: the view may disappear
    /// (island closes) while the user is still dragging.
    final class DragSource: NSObject, NSDraggingSource {
        private static var active: Set<DragSource> = []
        private let onDraggedOut: (() -> Void)?

        init(onDraggedOut: (() -> Void)?) {
            self.onDraggedOut = onDraggedOut
            super.init()
            Self.active.insert(self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? [.copy, .move, .link, .generic] : []
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            if !operation.isEmpty { DispatchQueue.main.async { self.onDraggedOut?() } }
            Self.active.remove(self)
        }
    }
}
