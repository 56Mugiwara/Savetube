import AppKit
import Combine
import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Persistent user-selected cover art, keyed by the library's stable media identity.
@MainActor
final class ArtworkOverrides: ObservableObject {
    static let shared = ArtworkOverrides()

    @Published private(set) var revision = 0
    @Published var lastError: String?

    private let fileManager = FileManager.default
    private let artworkDirectory: URL
    private var requests: [String: UUID] = [:]

    private init() {
        let root: URL
        if let override = ProcessInfo.processInfo.environment["SAVETUBE_DATA_DIR"], !override.isEmpty {
            root = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            root = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/SaveTube/Media", isDirectory: true)
        }
        artworkDirectory = root.appendingPathComponent(".artwork", isDirectory: true)
    }

    /// Presents an image picker and copies the selected image into the media library.
    func choose(file: MediaFile) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsOtherFileTypes = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Artwork"
        panel.begin { [weak self] response in
            guard response == .OK, let source = panel.url else { return }
            Task { await self?.set(imageURL: source, for: file) }
        }
    }

    func set(imageURL source: URL, for file: MediaFile) async {
        let request = UUID()
        requests[file.id] = request
        let destination = overrideURL(for: file)
        let temporary = artworkDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("image")
        do {
            try await Task.detached(priority: .utility) {
                try Self.stage(source: source, temporary: temporary)
            }.value
            guard requests[file.id] == request else {
                try? fileManager.removeItem(at: temporary)
                return
            }
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
            requests.removeValue(forKey: file.id)
            lastError = nil
            revision &+= 1
        } catch {
            try? fileManager.removeItem(at: temporary)
            guard requests[file.id] == request else { return }
            requests.removeValue(forKey: file.id)
            lastError = "Artwork could not be updated: \(error.localizedDescription)"
        }
    }

    func clear(file: MediaFile) {
        requests.removeValue(forKey: file.id)
        let destination = overrideURL(for: file)
        guard fileManager.fileExists(atPath: destination.path) else { return }
        do {
            try fileManager.removeItem(at: destination)
            lastError = nil
            revision &+= 1
        } catch {
            lastError = "Artwork could not be updated: \(error.localizedDescription)"
        }
    }

    /// Returns the custom image first, then an adjacent yt-dlp sidecar if present.
    func url(for file: MediaFile) -> URL? {
        let custom = overrideURL(for: file)
        if fileManager.isReadableFile(atPath: custom.path) { return custom }
        let base = file.url.deletingPathExtension()
        for ext in ["jpg", "jpeg", "png", "webp"] {
            let candidate = base.appendingPathExtension(ext)
            if fileManager.isReadableFile(atPath: candidate.path) { return candidate }
            let uppercase = base.appendingPathExtension(ext.uppercased())
            if fileManager.isReadableFile(atPath: uppercase.path) { return uppercase }
        }
        return nil
    }

    func customURL(for file: MediaFile) -> URL? {
        let url = overrideURL(for: file)
        return fileManager.isReadableFile(atPath: url.path) ? url : nil
    }

    func hasOverride(for file: MediaFile) -> Bool { customURL(for: file) != nil }

    func cacheSignature(for file: MediaFile) -> String {
        guard let url = url(for: file) else { return "none|revision:\(revision)" }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return "\(url.standardizedFileURL.path)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values?.fileSize ?? 0)|revision:\(revision)"
    }

    private func overrideURL(for file: MediaFile) -> URL {
        artworkDirectory.appendingPathComponent(Self.digest(file.id)).appendingPathExtension("image")
    }

    nonisolated private static func stage(source: URL, temporary: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: temporary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: source, to: temporary)
        guard let imageSource = CGImageSourceCreateWithURL(temporary as CFURL, nil),
              CGImageSourceGetCount(imageSource) > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
