import AppKit
import SwiftUI

/// Keeps library navigation local to this window and leaves text editing alone.
struct LibraryKeyboard: NSViewRepresentable {
    var onMove: (Int) -> Bool
    var onOpen: () -> Bool
    var onEscape: () -> Bool
    var onSpace: (() -> Bool)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.install()
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onMove = onMove
        context.coordinator.onOpen = onOpen
        context.coordinator.onEscape = onEscape
        context.coordinator.onSpace = onSpace
    }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.remove() }

    final class Coordinator {
        weak var view: NSView?
        var onMove: ((Int) -> Bool)?
        var onOpen: (() -> Bool)?
        var onEscape: (() -> Bool)?
        var onSpace: (() -> Bool)?
        private var monitor: Any?
        private var spaceConsumed = false
        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.view?.window,
                      event.window === window, window.isKeyWindow,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
                if event.keyCode == 53, self.onEscape?() == true { return nil }
                if let editor = window.firstResponder as? NSTextView, editor.isEditable { return event }
                if let field = window.firstResponder as? NSTextField, field.isEditable { return event }
                switch event.keyCode {
                case 126: return self.onMove?(-1) == true ? nil : event
                case 125: return self.onMove?(1) == true ? nil : event
                case 36, 76: return self.onOpen?() == true ? nil : event
                case 49:
                    if event.isARepeat { return self.spaceConsumed ? nil : event }
                    self.spaceConsumed = self.onSpace?() == true
                    return self.spaceConsumed ? nil : event
                default: return event
                }
            }
        }
        func remove() { if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil } }
        deinit { remove() }
    }
}
