import AppKit
import SwiftUI

struct WindowChrome: NSViewRepresentable {
    @Binding var nativeTopInset: CGFloat
    func makeNSView(context: Context) -> ChromeView { ChromeView() }
    func updateNSView(_ view: ChromeView, context: Context) {
        view.insetChanged = { nativeTopInset = $0 }
        view.applyChrome()
        // NavigationSplitView installs its toolbar during the same SwiftUI update.
        DispatchQueue.main.async { [weak view] in view?.applyChrome() }
    }

    final class ChromeView: NSView {
        private var windowUpdateObserver: NSObjectProtocol?
        var insetChanged: ((CGFloat) -> Void)?
        private var reportedInset: CGFloat = -1

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
            if let content = window.contentView {
                let inset = max(content.safeAreaInsets.top, max(0, content.bounds.height - window.contentLayoutRect.height))
                if abs(inset - reportedInset) > 0.5 {
                    reportedInset = inset
                    DispatchQueue.main.async { [weak self] in self?.insetChanged?(inset) }
                }
            }
        }
    }
}
