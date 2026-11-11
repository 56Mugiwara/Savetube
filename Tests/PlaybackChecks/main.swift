import AVFoundation
import Foundation
import Combine

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

        // A pause while a local item is preparing must win over ready callbacks.
        store.play(first, queue: [first, second])
        store.pause()
        try await until("paused item ready") { store.player.currentItem?.status == .readyToPlay }
        try await Task.sleep(nanoseconds: 250_000_000)
        guard !store.isPlaying, store.player.rate == 0 else { throw CheckFailure(description: "Readiness resumed an explicitly paused item") }
        store.toggle()
        try await until("resume after preparation") { store.player.rate > 0 && store.currentTime > 0.1 }
        let presentation = PlaybackPresentation.shared
        var structuralUpdates = 0
        let subscription = presentation.objectWillChange.sink { structuralUpdates += 1 }
        try await until("MP3 duration") { store.duration > 3 && store.player.currentItem?.status == .readyToPlay }
        try await until("embedded track metadata") { store.title == "Fixture Track" && store.artist == "Fixture Artist" }
        try await until("MP3 playback time advances") { store.currentTime > 0.3 }
        guard store.currentFile == first, store.player.currentItem != nil else { throw CheckFailure(description: "MP3 was not loaded into AVPlayer") }

        let beforeClock = structuralUpdates
        try await Task.sleep(nanoseconds: 550_000_000)
        guard structuralUpdates == beforeClock else { throw CheckFailure(description: "Playback clock invalidated structural library presentation") }
        subscription.cancel()
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

        store.play(first, queue: [first, second])
        store.toggleShuffle()
        guard store.shuffleEnabled, Set(store.queue.map(\.id)) == Set([first.id, second.id]) else { throw CheckFailure(description: "Shuffle lost queue tracks") }
        store.toggleShuffle()
        guard !store.shuffleEnabled, store.queue == [first, second] else { throw CheckFailure(description: "Disabling shuffle did not restore queue order") }
        store.cycleRepeat()
        guard store.repeatMode == .all else { throw CheckFailure(description: "Repeat all was not enabled") }
        store.play(second, queue: [first, second]); store.next()
        guard store.currentFile == first else { throw CheckFailure(description: "Repeat all did not wrap the queue") }
        store.cycleRepeat()
        guard store.repeatMode == .one else { throw CheckFailure(description: "Repeat one was not enabled") }
        store.cycleRepeat()
        guard store.repeatMode == .off else { throw CheckFailure(description: "Repeat did not cycle off") }
        store.moveQueueItems(from: IndexSet(integer: 0), to: 2)
        guard store.queue == [second, first] else { throw CheckFailure(description: "Queue reordering failed") }
        store.removeFromQueue(second)
        guard store.queue == [first] else { throw CheckFailure(description: "Removing an upcoming queue item failed") }
        let wasFavorite = store.favoriteIDs.contains(first.id)
        store.toggleFavorite()
        guard store.favoriteIDs.contains(first.id) != wasFavorite else { throw CheckFailure(description: "Favorite did not toggle") }
        store.toggleFavorite()

        store.stop()
        guard store.currentFile == nil, store.player.currentItem == nil, !store.isPlaying,
              store.duration == 0, store.currentTime == 0, store.error == nil else {
            throw CheckFailure(description: "Stop did not reset player state")
        }
        print("PASS playback: MP3 and MP4 AVPlayer loading, duration, advancing time, pause, seek, queue navigation, missing file, metadata, shuffle, repeat, queue editing, favorites, stop")
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
