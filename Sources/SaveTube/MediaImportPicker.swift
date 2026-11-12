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

/// Shares one nonblocking destination sheet between the two workspaces.
@MainActor
final class MediaMovePicker {
    static let shared = MediaMovePicker()
    private let panel: NSOpenPanel
    private var presenting = false

    private init() {
        panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Move Here"
    }

    func open(for file: MediaFile, completion: @escaping (URL) -> Void) {
        guard !presenting else { return }
        presenting = true
        panel.directoryURL = file.url.deletingLastPathComponent()
        let finished: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            self.presenting = false
            if response == .OK, let url = self.panel.url { completion(url) }
        }
        if let window = NSApplication.shared.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finished)
        } else {
            panel.begin(completionHandler: finished)
        }
    }
}
