import Foundation
import Combine
import Darwin

/// Swift orchestration of the bundled yt-dlp/FFmpeg executables. No shell is involved.
@MainActor
final class DownloadEngine: ObservableObject {
    @Published var status = ""
    @Published var progress: Double = 0
    @Published var isRunning = false

    private struct Job {
        let url: String
        let format: String
        let destination: URL
    }
    private var lastJob: Job?
    private var control: DownloadControl?
    private var operationID = UUID()

    func start(url: String, format: String, destination: URL, completion: @escaping () -> Void) {
        guard !isRunning else { status = "A download is already running..."; return }
        let text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URLComponents(string: text),
              ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
              let host = parsed.host, !host.isEmpty else {
            status = "Please paste a valid HTTP or HTTPS video link first."
            return
        }
        guard ["MP4", "MP3", "Both"].contains(format) else {
            status = "Choose MP4, MP3, or Both."
            return
        }
        let job = Job(url: text, format: format, destination: destination)
        lastJob = job
        let identifier = UUID()
        operationID = identifier
        let token = DownloadControl()
        control = token
        progress = 0
        status = "Processing download... Please wait."
        isRunning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let downloader = try Self.executable(named: "yt-dlp")
                let ffmpeg = try Self.executable(named: "ffmpeg")
                let formats = job.format == "Both" ? ["MP4", "MP3"] : [job.format]
                for (stage, kind) in formats.enumerated() {
                    try token.checkCancellation()
                    let folder = job.destination.appendingPathComponent(kind, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let archive = folder.appendingPathComponent(".download-archive.txt")
                    var args = ["--ignore-config", "--no-playlist", "--newline", "--no-color", "--progress", "--continue",
                                "--no-overwrites", "--write-thumbnail", "--download-archive", archive.path,
                                "--ffmpeg-location", ffmpeg.deletingLastPathComponent().path,
                                "--progress-template", "download:SAVETUBE_PROGRESS:%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s",
                                "--print", "after_move:SAVETUBE_FILE:%(filepath)s", "--no-simulate",
                                "--output", folder.appendingPathComponent("%(title)s [%(id)s].%(ext)s").path]
                    if kind == "MP4" {
                        args += ["--format", "bestvideo[vcodec^=avc1]+bestaudio[ext=m4a]/best[ext=mp4]/best", "--merge-output-format", "mp4"]
                    } else {
                        args += ["--format", "bestaudio/best", "--extract-audio", "--audio-format", "mp3", "--audio-quality", "192K"]
                    }
                    args += ["--", job.url]
                    DispatchQueue.main.async { self?.status = "Downloading \(kind)..." }
                    try Self.run(executable: downloader, arguments: args, control: token) { line in
                        if line.hasPrefix("SAVETUBE_PROGRESS:") {
                            let fields = line.dropFirst("SAVETUBE_PROGRESS:".count).split(separator: "|", omittingEmptySubsequences: false)
                            let percent = Double((fields.first.map(String.init) ?? "0").replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) ?? 0
                            let overall = (Double(stage) + min(100, max(0, percent)) / 100) / Double(formats.count)
                            let detail = fields.dropFirst().map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != "NA" }.joined(separator: "  ·  ")
                            DispatchQueue.main.async {
                                self?.progress = overall
                                self?.status = "\(kind)  ·  \(Int(percent))%" + (detail.isEmpty ? "" : "  ·  \(detail)")
                            }
                        } else if line.contains("[Merger]") || line.contains("[ExtractAudio]") {
                            DispatchQueue.main.async { self?.status = kind == "MP3" ? "Converting to MP3…" : "Merging video and audio…" }
                        }
                    }
                    try token.checkCancellation()
                }
                DispatchQueue.main.async {
                    self?.progress = 1
                    self?.status = "Download success"
                    self?.isRunning = false
                    self?.control = nil
                    completion()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                        guard let self, self.operationID == identifier, !self.isRunning else { return }
                        self.progress = 0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                        guard let self, self.operationID == identifier, !self.isRunning, self.status == "Download success" else { return }
                        self.status = ""
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.status = token.isCancelled ? "Download cancelled. Use Retry Download to resume." : error.localizedDescription
                    self?.isRunning = false
                    self?.progress = 0
                    self?.control = nil
                    completion()
                }
            }
        }
    }

    func cancel() {
        guard isRunning else { return }
        status = "Cancelling download…"
        control?.cancel()
    }

    func retry(completion: @escaping () -> Void) {
        guard let job = lastJob else { status = "There is no download to retry."; return }
        start(url: job.url, format: job.format, destination: job.destination, completion: completion)
    }

    nonisolated private static func executable(named name: String) throws -> URL {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)").path
        if Bundle.main.bundleURL.pathExtension.lowercased() == "app" {
            guard FileManager.default.isExecutableFile(atPath: bundled) else {
                throw DownloadFailure("Missing \(name). Install the complete MediaFetch release with its bundled helpers.")
            }
            return URL(fileURLWithPath: bundled)
        }
        let paths = [bundled,
                     "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)",
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Python/3.9/bin/\(name)").path]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/\(name)" }
        if let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return URL(fileURLWithPath: path) }
        throw DownloadFailure("Missing \(name). Install the complete MediaFetch release with its bundled download helpers.")
    }

    nonisolated private static func run(executable: URL, arguments: [String], control: DownloadControl,
                                       line: (String) throws -> Void) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        if Bundle.main.bundleURL.pathExtension.lowercased() == "app" {
            environment["PATH"] = executable.deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        } else {
            environment["PATH"] = executable.deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try control.launch(process)
        // Close this parent's writer so EOF follows the actual child exit.
        try? pipe.fileHandleForWriting.close()
        var buffer = Data()
        var recent: [String] = []
        var callbackFailure: Error?
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                let record = String(decoding: buffer[..<newline], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                buffer.removeSubrange(...newline)
                if !record.isEmpty {
                    recent.append(record)
                    if recent.count > 12 { recent.removeFirst() }
                    do { try line(record) } catch { callbackFailure = error }
                }
            }
        }
        if !buffer.isEmpty {
            let record = String(decoding: buffer, as: UTF8.self)
            recent.append(record)
            do { try line(record) } catch { callbackFailure = error }
        }
        process.waitUntilExit()
        control.finished(process)
        try control.checkCancellation()
        guard process.terminationStatus == 0 else {
            let details = recent.last(where: { $0.contains("ERROR:") }) ?? recent.suffix(3).joined(separator: "\n")
            throw DownloadFailure(details.isEmpty ? "Download failed (exit \(process.terminationStatus))." : details)
        }
        if let error = callbackFailure { throw error }
    }


}

private struct DownloadFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Shared between the main thread and the blocking subprocess reader.
private final class DownloadControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func checkCancellation() throws { if isCancelled { throw DownloadFailure("Download cancelled.") } }
    func launch(_ task: Process) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw DownloadFailure("Download cancelled.") }
        try task.run()
        process = task
    }
    func finished(_ task: Process) {
        lock.lock(); defer { lock.unlock() }
        if process === task { process = nil }
    }
    func cancel() {
        lock.lock()
        cancelled = true
        let task = process
        lock.unlock()
        guard let task else { return }
        do {
            guard task.isRunning else { return }
            // FFmpeg is a direct yt-dlp child. Stop children first so they close
            // their inherited pipe and no conversion survives cancellation.
            let killer = Process()
            killer.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            killer.arguments = ["-TERM", "-P", String(task.processIdentifier)]
            killer.standardOutput = FileHandle.nullDevice
            killer.standardError = FileHandle.nullDevice
            do {
                try killer.run()
                killer.waitUntilExit()
            } catch { /* Terminating the downloader still handles launch failures. */ }
            if task.isRunning { task.terminate() }
        }
    }
}
