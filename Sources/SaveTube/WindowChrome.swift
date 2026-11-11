import AppKit
import SwiftUI

struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> ChromeView { ChromeView() }
    func updateNSView(_ view: ChromeView, context: Context) {
        view.applyChrome()
        // NavigationSplitView installs its toolbar during the same SwiftUI update.
        DispatchQueue.main.async { [weak view] in view?.applyChrome() }
    }

    final class ChromeView: NSView {
        private var windowUpdateObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let windowUpdateObserver { NotificationCenter.default.removeObserver(windowUpdateObserver) }
            windowUpdateObserver = nil
            if let window {
                windowUpdateObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didUpdateNotification, object: window, queue: .main
                ) { [weak self] _ in self?.applyChrome() }
            }
            applyChrome()
        }

        deinit {
            if let windowUpdateObserver { NotificationCenter.default.removeObserver(windowUpdateObserver) }
        }

        func applyChrome() {
            guard let window else { return }
            if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
            if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
            if !window.styleMask.contains(.fullSizeContentView) { window.styleMask.insert(.fullSizeContentView) }
            if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
            if !window.isMovableByWindowBackground { window.isMovableByWindowBackground = true }
            if let toolbar = window.toolbar, toolbar.isVisible { toolbar.isVisible = false }
        }
    }
}
