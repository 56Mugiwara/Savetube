import AVFoundation
import Foundation

// Keep this check independent of the library UI and its SwiftUI macro toolchain.
struct MediaFile: Identifiable, Hashable {
    let url: URL
    let kind: String
    var id: String { "[\(kind)] \(url.lastPathComponent)" }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct PlaybackChecks {
    @MainActor
    static func main() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SAVETUBE_TEST_ROOT"]!)
        let first = MediaFile(url: root.appendingPathComponent("first.mp3"), kind: "MP3")
        let second = MediaFile(url: root.appendingPathComponent("second.mp4"), kind: "MP4")
        let missing = MediaFile(url: root.appendingPathComponent("missing.mp3"), kind: "MP3")
        let store = PlaybackStore.shared
        store.volume = 0
        defer { store.stop() }

        store.play(first, queue: [first, second])
        try await until("MP3 duration") { store.duration > 3 && store.player.currentItem?.status == .readyToPlay }
        try await until("MP3 playback time advances") { store.currentTime > 0.3 }
        guard store.currentFile == first, store.player.currentItem != nil else { throw CheckFailure(description: "MP3 was not loaded into AVPlayer") }

        store.pause()
        let pausedAt = store.currentTime
        try await Task.sleep(nanoseconds: 600_000_000)
        guard abs(store.currentTime - pausedAt) < 0.2 else { throw CheckFailure(description: "Pause did not hold playback position") }
        store.seek(to: 2)
        try await until("seek to two seconds") { abs(store.currentTime - 2) < 0.3 }

        store.next()
        try await until("MP4 duration") { store.currentFile == second && store.duration > 3 && store.player.currentItem?.status == .readyToPlay }
        try await until("MP4 playback time advances") { store.currentTime > 0.2 }
        store.previous()
        guard store.currentFile == first else { throw CheckFailure(description: "Previous did not return to first queued file") }

        store.play(missing, queue: [missing])
        guard store.error != nil, store.currentFile == first else { throw CheckFailure(description: "Missing file did not report an error and preserve current media") }

        store.stop()
        guard store.currentFile == nil, store.player.currentItem == nil, !store.isPlaying,
              store.duration == 0, store.currentTime == 0, store.error == nil else {
            throw CheckFailure(description: "Stop did not reset player state")
        }
        print("PASS playback: MP3 and MP4 AVPlayer loading, duration, advancing time, pause, seek, queue navigation, missing file, stop")
    }

    @MainActor
    private static func until(_ description: String, timeout: TimeInterval = 8, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw CheckFailure(description: "Timed out waiting for \(description)")
    }
}
