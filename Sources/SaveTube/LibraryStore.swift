import AppKit
import Combine
import CryptoKit
import Foundation
import Darwin

struct MediaFile: Identifiable, Hashable {
    let url: URL
    let kind: String
    let stableID: String?
    init(url: URL, kind: String, stableID: String? = nil) {
        self.url = url
        self.kind = kind
        self.stableID = stableID
    }
    var id: String { stableID ?? "[\(kind)] \(url.lastPathComponent)" }
    var key: String { id }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// Virtual folders group files without moving the underlying media on disk.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var files: [MediaFile] = []
    @Published private(set) var folders: [String] = []
    @Published private(set) var assignments: [String: String] = [:]
    @Published var expanded: Set<String> = []
    @Published var lastError: String?
    @Published private(set) var isImporting = false
    private var activeImports = 0
    nonisolated private static let importQueue = DispatchQueue(label: "SaveTube.media-import", qos: .userInitiated)
    let root: URL

    private struct Metadata: Codable {
        var folders: [String]
        var assign: [String: String]
    }
    private struct TrackedFile: Codable {
        var bookmark: Data
        var kind: String
        var lastPath: String
        var identity: String?
    }
    private var tracked: [String: TrackedFile] = [:]
    private var trackedURL: URL { root.appendingPathComponent(".tracked-files.json") }
    private var metadataURL: URL { root.appendingPathComponent(".library.json") }
    private let manager = FileManager.default
    private var canSave = true
    private var savedMetadata: Data?
    private var savedTracking: Data?
    private let trashHandler: ((URL) throws -> Void)?

    init(root: URL? = nil, trashHandler: ((URL) throws -> Void)? = nil) {
        self.trashHandler = trashHandler
        if let root = root {
            self.root = root
        } else if let override = ProcessInfo.processInfo.environment["SAVETUBE_DATA_DIR"], !override.isEmpty {
            self.root = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            self.root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/SaveTube/Media", isDirectory: true)
        }
        do {
            for kind in ["MP4", "MP3"] {
                try manager.createDirectory(at: self.root.appendingPathComponent(kind), withIntermediateDirectories: true)
            }
            if manager.fileExists(atPath: metadataURL.path) {
                let metadata = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: metadataURL))
                folders = Array(Set(metadata.folders.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }))
                    .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                assignments = metadata.assign
            }
        } catch {
            // Keep corrupt or temporarily unreadable metadata intact for recovery.
            canSave = false
            lastError = "Could not load the library: \(error.localizedDescription)"
        }
        do {
            if manager.fileExists(atPath: trackedURL.path) {
                tracked = try JSONDecoder().decode([String: TrackedFile].self, from: Data(contentsOf: trackedURL))
            }
        } catch {
            canSave = false
            lastError = "Could not load file locations: \(error.localizedDescription)"
        }
        expanded = Set(folders)
        refresh()
    }

    func refresh() {
        do {
            var scanned: [MediaFile] = []
            var seenPaths = Set<String>()
            for id in tracked.keys.sorted() {
                guard let file = resolve(id: id) else { continue }
                if seenPaths.insert(canonicalPath(file.url)).inserted { scanned.append(file) }
            }
            for kind in ["MP4", "MP3"] {
                let directory = root.appendingPathComponent(kind, isDirectory: true)
                let urls = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
                for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension.lowercased() == kind.lowercased() {
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true,
                          seenPaths.insert(canonicalPath(url)).inserted else { continue }
                    let baseID = "[\(kind)] \(url.lastPathComponent)"
                    let id = tracked[baseID] == nil ? baseID : baseID + "#" + UUID().uuidString
                    let file = MediaFile(url: url, kind: kind, stableID: id)
                    scanned.append(file)
                    try register(file)
                }
            }
            let nextFiles = scanned.sorted {
                let order = $0.name.localizedCaseInsensitiveCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
            if files != nextFiles { files = nextFiles }
            let validFolders = Set(folders)
            // Temporarily missing files keep their assignments and bookmarks so a
            // later reappearance can restore the same row and folder membership.
            let nextAssignments = assignments.filter { validFolders.contains($0.value) }
            if assignments != nextAssignments { assignments = nextAssignments }
            save()
        } catch {
            lastError = "Could not refresh the library: \(error.localizedDescription)"
        }
    }

    private func canonicalPath(_ url: URL) -> String {
        if let resolved = realpath(url.path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func fileIdentity(_ url: URL) -> String? {
        var attributes = stat()
        guard lstat(url.path, &attributes) == 0, (attributes.st_mode & S_IFMT) == S_IFREG else { return nil }
        return "\(attributes.st_dev):\(attributes.st_ino)"
    }

    private func register(_ file: MediaFile) throws {
        guard canSave else { return }
        let bookmark = try file.url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        tracked[file.id] = TrackedFile(bookmark: bookmark, kind: file.kind, lastPath: file.url.path, identity: fileIdentity(file.url))
    }

    private func resolve(id: String) -> MediaFile? {
        guard var record = tracked[id] else { return nil }
        var stale = false
        let bookmarkURL = try? URL(resolvingBookmarkData: record.bookmark,
            options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
        let fallback = URL(fileURLWithPath: record.lastPath)
        guard let url = [bookmarkURL, fallback].compactMap({ $0 }).first(where: {
            guard let identity = fileIdentity($0) else { return false }
            return record.identity == nil || record.identity == identity
        }) else { return nil }
        let file = MediaFile(url: url, kind: record.kind, stableID: id)
        if stale || record.lastPath != url.path || record.identity == nil {
            if let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                record.bookmark = bookmark
                record.lastPath = url.path
                record.identity = fileIdentity(url)
                tracked[id] = record
            }
        }
        return file
    }

    private func current(_ file: MediaFile) -> MediaFile? {
        if let resolved = resolve(id: file.id) { return resolved }
        lastError = "The file is unavailable. Reconnect its disk or return it to its previous location."
        return nil
    }

    /// Copies the original .Dmp3/.Dmp4 history into the native library while
    /// retaining every source file and preserving virtual folder assignments.
    func importLegacy(from directory: URL) {
        guard canSave else {
            lastError = "Repair the current library metadata before importing history."
            return
        }
        var sourceRoot = directory
        if [".Dmp3", ".Dmp4", "MP3", "MP4"].contains(directory.lastPathComponent) {
            sourceRoot = directory.deletingLastPathComponent()
        }
        guard sourceRoot.resolvingSymlinksInPath().standardizedFileURL != root.resolvingSymlinksInPath().standardizedFileURL else {
            refresh()
            return
        }
        var problems: [String] = []
        var importedMetadata: Metadata?
        let sourceMetadata = sourceRoot.appendingPathComponent(".library.json")
        if manager.fileExists(atPath: sourceMetadata.path) {
            do {
                importedMetadata = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: sourceMetadata))
            } catch {
                problems.append("The original folder metadata could not be read: \(error.localizedDescription)")
            }
        }
        var mappedPaths: [String: URL] = [:]
        var foundDirectory = false
        for kind in ["MP3", "MP4"] {
            let destination = root.appendingPathComponent(kind, isDirectory: true)
            for oldName in [kind == "MP3" ? ".Dmp3" : ".Dmp4", kind] {
                let sourceDirectory = sourceRoot.appendingPathComponent(oldName, isDirectory: true)
                var isDirectory: ObjCBool = false
                guard manager.fileExists(atPath: sourceDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                foundDirectory = true
                do {
                    let candidates = try manager.contentsOfDirectory(at: sourceDirectory,
                        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
                    for source in candidates.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                        guard source.pathExtension.lowercased() == kind.lowercased() else { continue }
                        do {
                            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                            let importedURL = try importMedia(source, to: destination)
                            let oldKey = "[\(kind)] \(source.lastPathComponent)"
                            // The original hidden directory takes precedence if both
                            // old and modern layouts exist in the selected folder.
                            if mappedPaths[oldKey] == nil {
                                mappedPaths[oldKey] = importedURL
                            }
                        } catch {
                            problems.append("\(source.lastPathComponent): \(error.localizedDescription)")
                        }
                    }
                } catch {
                    problems.append("\(oldName): \(error.localizedDescription)")
                }
            }
        }
        if !foundDirectory {
            lastError = "Choose the folder containing .Dmp3/.Dmp4 or MP3/MP4 history directories."
            return
        }
        // Register copied destinations before assigning virtual folders: a reused
        // filename can have a different stable ID from an older moved file.
        refresh()
        if let metadata = importedMetadata {
            for folder in metadata.folders where !folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !folders.contains(folder) { folders.append(folder) }
                expanded.insert(folder)
            }
            folders.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            for (oldKey, folder) in metadata.assign {
                guard let importedURL = mappedPaths[oldKey],
                      let importedFile = files.first(where: { canonicalPath($0.url) == canonicalPath(importedURL) }),
                      folders.contains(folder), assignments[importedFile.id] == nil else { continue }
                assignments[importedFile.id] = folder
            }
        }
        save()
        refresh()
        if !problems.isEmpty { lastError = "Some history could not be imported:\n" + problems.joined(separator: "\n") }
    }

    private func importMedia(_ source: URL, to directory: URL) throws -> URL {
        try Self.copyImportedMedia(source, to: directory)
    }

    nonisolated private static func copyImportedMedia(_ source: URL, to directory: URL) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let digest = try mediaDigest(source)
        var destination = directory.appendingPathComponent(source.lastPathComponent)
        var suffix = 0
        while manager.fileExists(atPath: destination.path) {
            if try mediaDigest(destination) == digest { return destination }
            suffix += 1
            destination = directory.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent) (\(suffix)).\(source.pathExtension)")
        }
        let staging = directory.appendingPathComponent(".import-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staging) }
        try manager.copyItem(at: source, to: staging)
        guard try mediaDigest(staging) == digest else { throw CocoaError(.fileReadCorruptFile) }
        try manager.moveItem(at: staging, to: destination)
        return destination
    }

    nonisolated private static func mediaDigest(_ url: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize()
    }

    func createFolder(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !folders.contains(name), canSave else { return }
        folders.append(name)
        folders.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        expanded.insert(name)
        save()
    }

    func renameFolder(_ old: String, to new: String) {
        let name = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard folders.contains(old), !name.isEmpty, name != old, !folders.contains(name), canSave else { return }
        folders = folders.map { $0 == old ? name : $0 }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        assignments = assignments.mapValues { $0 == old ? name : $0 }
        if expanded.remove(old) != nil { expanded.insert(name) }
        save()
    }

    func deleteFolder(_ name: String) {
        guard canSave else { return }
        folders.removeAll { $0 == name }
        assignments = assignments.filter { $0.value != name }
        expanded.remove(name)
        save()
    }

    func assign(_ file: MediaFile, to folder: String?) {
        guard files.contains(where: { $0.id == file.id }), canSave else { return }
        if let folder = folder {
            guard folders.contains(folder) else { return }
            assignments[file.id] = folder
            expanded.insert(folder)
        } else {
            assignments.removeValue(forKey: file.id)
        }
        save()
    }

    private struct ImportResult {
        var urls: [URL] = []
        var problems: [String] = []
    }

    nonisolated private static func copyImports(_ urls: [URL], root: URL) -> ImportResult {
        var result = ImportResult()
        for source in urls {
            let kind = source.pathExtension.uppercased()
            guard ["MP3", "MP4"].contains(kind) else {
                result.problems.append("\(source.lastPathComponent): choose an MP3 or MP4 file.")
                continue
            }
            do {
                let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                result.urls.append(try copyImportedMedia(source, to: root.appendingPathComponent(kind, isDirectory: true)))
            } catch { result.problems.append("\(source.lastPathComponent): \(error.localizedDescription)") }
        }
        return result
    }

    private func finishImport(_ result: ImportResult, folder: String?) {
        if let folder = folder, !folders.contains(folder) { createFolder(folder) }
        refresh()
        if let folder = folder {
            let importedPaths = Set(result.urls.map(canonicalPath))
            for file in files where importedPaths.contains(canonicalPath(file.url)) { assign(file, to: folder) }
        }
        if !result.problems.isEmpty { lastError = result.problems.joined(separator: "\n") }
    }

    /// Synchronous entry point retained for scripted callers and isolated checks.
    func importMedia(urls: [URL], folder: String? = nil) {
        guard canSave else { return }
        finishImport(Self.copyImports(urls, root: root), folder: folder)
    }

    /// Hashing and filesystem copying run serially off the main thread. Multiple
    /// file drops queue safely and keep the busy state set until all have merged.
    func importMediaAsync(urls: [URL], folder: String? = nil) {
        guard canSave, !urls.isEmpty else { return }
        activeImports += 1
        isImporting = true
        let destinationRoot = root
        Self.importQueue.async { [weak self] in
            let result = Self.copyImports(urls, root: destinationRoot)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.finishImport(result, folder: folder)
                self.activeImports -= 1
                self.isImporting = self.activeImports > 0
            }
        }
    }

    func rename(_ file: MediaFile, to name: String) {
        guard let actual = current(file) else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":"), !name.contains("\0") else {
            lastError = "Choose a filename without slashes, colons, or control characters."
            return
        }
        var destination = actual.url.deletingLastPathComponent().appendingPathComponent(name)
        if destination.pathExtension.isEmpty { destination.appendPathExtension(actual.url.pathExtension) }
        guard destination.pathExtension.lowercased() == actual.url.pathExtension.lowercased() else {
            lastError = "Keep the file's original extension when renaming it."
            return
        }
        relocate(actual, to: destination)
    }

    func move(_ file: MediaFile, to directory: URL) {
        guard let actual = current(file) else { return }
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            lastError = "Choose an existing destination folder."
            return
        }
        relocate(actual, to: directory.appendingPathComponent(actual.url.lastPathComponent))
    }

    private func relocate(_ file: MediaFile, to destination: URL) {
        guard canSave else { return }
        if canonicalPath(file.url) == canonicalPath(destination) { return }
        do {
            try manager.moveItem(at: file.url, to: destination)
            try register(MediaFile(url: destination, kind: file.kind, stableID: file.id))
            save()
            refresh()
        } catch {
            lastError = "Could not move or rename the file: \(error.localizedDescription)"
            refresh()
        }
    }

    private func sendToTrash(_ url: URL) throws {
        if let trashHandler = trashHandler { try trashHandler(url) }
        else { try manager.trashItem(at: url, resultingItemURL: nil) }
    }

    func trash(_ file: MediaFile) {
        guard let actual = current(file) else { return }
        do {
            try sendToTrash(actual.url)
            assignments.removeValue(forKey: file.id)
            tracked.removeValue(forKey: file.id)
            save()
            refresh()
        } catch {
            lastError = "Could not move the file to Trash: \(error.localizedDescription)"
        }
    }

    func trashFolder(_ name: String, includingFiles: Bool) {
        guard includingFiles else { deleteFolder(name); return }
        refresh()
        let members = assignments.filter { $0.value == name }.map(\.key)
        var failures: [String] = []
        for id in members {
            guard let actual = resolve(id: id) else {
                failures.append("A file in this folder is unavailable.")
                continue
            }
            do {
                try sendToTrash(actual.url)
                assignments.removeValue(forKey: id)
                tracked.removeValue(forKey: id)
            } catch { failures.append(error.localizedDescription) }
        }
        // Keep the folder and failed members if any file could not be trashed.
        if failures.isEmpty { deleteFolder(name) }
        save()
        refresh()
        if !failures.isEmpty { lastError = failures.joined(separator: "\n") }
    }

    func reveal(_ file: MediaFile) {
        guard let actual = current(file) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([actual.url])
        refresh()
    }

    func open(_ file: MediaFile) {
        guard let actual = current(file) else { return }
        if !NSWorkspace.shared.open(actual.url) {
            lastError = "Could not open \(actual.url.lastPathComponent)."
        }
        refresh()
    }

    private func save() {
        guard canSave else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(Metadata(folders: folders, assign: assignments))
            if data != savedMetadata {
                try data.write(to: metadataURL, options: .atomic)
                savedMetadata = data
            }
            let trackedData = try encoder.encode(tracked)
            if trackedData != savedTracking {
                try trackedData.write(to: trackedURL, options: .atomic)
                savedTracking = trackedData
            }
        } catch {
            lastError = "Could not save the library: \(error.localizedDescription)"
        }
    }
}
