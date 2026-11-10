import CryptoKit
import Darwin
import Foundation

/// The two original destination scripts, implemented as modes of the Swift executable.
/// Each child owns one media format, so records and temporary output never collide.
enum BackgroundCopier {
    private struct Observation: Equatable {
        let size: Int64
        let modified: Date
    }

    static func run(kind: String, root: URL) {
        guard ["MP3", "MP4"].contains(kind) else { return }
        let manager = FileManager.default
        let sourceDirectory = root.appendingPathComponent(kind, isDirectory: true)
        let downloads: URL
        if let override = ProcessInfo.processInfo.environment["SAVETUBE_DOWNLOADS_DIR"], !override.isEmpty {
            downloads = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            downloads = manager.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        }
        let recordsURL = root.appendingPathComponent(".\(kind.lowercased())-copies.json")
        let parentPID = getppid()
        var observations: [String: Observation] = [:]
        var copied: [String: String] = [:]
        var fingerprints: [String: (Observation, String)] = [:]
        if let data = try? Data(contentsOf: recordsURL),
           let records = try? JSONDecoder().decode([String: String].self, from: data) {
            copied = records
        }
        do {
            try manager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
            try manager.createDirectory(at: downloads, withIntermediateDirectories: true)
        } catch {
            log("Could not start \(kind) destination helper: \(error.localizedDescription)")
            return
        }
        // SIGTERM uses the system's normal termination behavior. An interrupted copy
        // only leaves an invisible staging file; it can never expose a partial MP3/MP4.
        // Remove staging files left by an earlier interrupted helper of this format.
        if let oldFiles = try? manager.contentsOfDirectory(at: downloads, includingPropertiesForKeys: nil) {
            for file in oldFiles where file.lastPathComponent.hasPrefix(".savetube-\(kind.lowercased())-") && file.pathExtension == "copying" {
                let ownerText = file.lastPathComponent.dropFirst(".savetube-\(kind.lowercased())-".count).split(separator: "-").first
                if let text = ownerText, let owner = Int32(text), kill(owner, 0) == -1, errno == ESRCH {
                    try? manager.removeItem(at: file)
                }
            }
        }
        while getppid() == parentPID && parentPID > 1 {
            autoreleasepool {
                do {
                    let candidates = try manager.contentsOfDirectory(at: sourceDirectory,
                        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
                        options: [.skipsHiddenFiles])
                    var present = Set<String>()
                    for source in candidates {
                        let filename = source.lastPathComponent
                        guard source.pathExtension.lowercased() == kind.lowercased(),
                              ![".temp", ".tmp", ".crdownload", ".part", ".download"].contains(where: filename.lowercased().contains) else { continue }
                        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                        guard values.isRegularFile == true, values.isSymbolicLink != true,
                              let size = values.fileSize, size > 0, let modified = values.contentModificationDate else { continue }
                        present.insert(filename)
                        let observation = Observation(size: Int64(size), modified: modified)
                        let previous = observations.updateValue(observation, forKey: filename)
                        // Two equal observations, at least one second apart, indicate
                        // a finished file. yt-dlp keeps active downloads under .part.
                        guard previous == observation else { continue }
                        do {
                            let digest: String
                            if let cached = fingerprints[filename], cached.0 == observation {
                                digest = cached.1
                            } else {
                                digest = try hash(source)
                                fingerprints[filename] = (observation, digest)
                            }
                            guard copied[filename] != digest else { continue }
                            // Recheck after hashing in case a producer resumed writing.
                            let after = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                            guard after.fileSize == size, after.contentModificationDate == modified else { continue }
                            try copy(source, to: downloads, kind: kind, digest: digest)
                            copied[filename] = digest
                            let data = try JSONEncoder().encode(copied)
                            try data.write(to: recordsURL, options: .atomic)
                        } catch {
                            log("\(kind) copy failed for \(filename): \(error.localizedDescription)")
                        }
                    }
                    observations = observations.filter { present.contains($0.key) }
                    fingerprints = fingerprints.filter { present.contains($0.key) }
                } catch {
                    log("\(kind) destination monitor: \(error.localizedDescription)")
                }
            }
            Thread.sleep(forTimeInterval: 1)
        }
    }

    private static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func copy(_ source: URL, to directory: URL, kind: String, digest: String) throws {
        let manager = FileManager.default
        var suffix = 0
        var destination = directory.appendingPathComponent(source.lastPathComponent)
        // Existing identical content is the same completed copy, including recovery
        // from a crash between the atomic move and saving the copy record.
        while manager.fileExists(atPath: destination.path) {
            if (try? hash(destination)) == digest { return }
            suffix += 1
            destination = directory.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent) (\(suffix)).\(source.pathExtension)")
        }
        let staging = directory.appendingPathComponent(".savetube-\(kind.lowercased())-\(getpid())-\(UUID().uuidString).copying")
        defer { try? manager.removeItem(at: staging) }
        try manager.copyItem(at: source, to: staging)
        // Ensure the staged copy really matches the completed source observed above.
        guard try hash(staging) == digest else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // moveItem fails rather than overwriting if another writer won the name.
        try manager.moveItem(at: staging, to: destination)
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

@MainActor
final class HelperSupervisor {
    private var helpers: [Process] = []

    func start(root: URL) {
        stop()
        guard let executable = Bundle.main.executableURL else { return }
        for kind in ["MP3", "MP4"] {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["--copy-helper", kind, "--media-root", root.path]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            // Preserve diagnostics in the app's stderr without exposing any UI.
            process.standardError = FileHandle.standardError
            do {
                try process.run()
                helpers.append(process)
            } catch {
                FileHandle.standardError.write(Data("Could not launch \(kind) copy helper: \(error.localizedDescription)\n".utf8))
            }
        }
    }

    func stop() {
        for helper in helpers where helper.isRunning { helper.terminate() }
        helpers.removeAll()
    }

    deinit {
        for helper in helpers where helper.isRunning { helper.terminate() }
    }
}
