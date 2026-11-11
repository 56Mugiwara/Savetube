import AppKit
import UniformTypeIdentifiers

/// Reuses the native picker and presents a sheet without a nested modal run loop.
@MainActor
final class MediaImportPicker {
    static let shared = MediaImportPicker()
    private let panel: NSOpenPanel
    private var presenting = false

    private init() {
        panel = NSOpenPanel()
        panel.allowedContentTypes = [.mp3, .mpeg4Movie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Import"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    func open(completion: @escaping ([URL]) -> Void) {
        guard !presenting else { return }
        presenting = true
        let finished: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            self.presenting = false
            if response == .OK { completion(self.panel.urls) }
        }
        if let window = NSApplication.shared.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finished)
        } else {
            panel.begin(completionHandler: finished)
        }
    }
}
