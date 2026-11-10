import Foundation

struct MediaFile {
    let url: URL
}

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct VisualizationChecks {
    @MainActor
    static func main() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SAVETUBE_TEST_ROOT"]!)
        let store = AudioVisualizationStore.shared
        let silent = MediaFile(url: root.appendingPathComponent("silent.mp3"))
        let tone = MediaFile(url: root.appendingPathComponent("tone.mp3"))
        let movie = MediaFile(url: root.appendingPathComponent("tone.mp4"))
        let pulse = MediaFile(url: root.appendingPathComponent("pulse.mp3"))

        store.prepare(file: silent)
        try await untilReady(store)
        guard store.bands(at: 0.5).allSatisfy({ $0 == 0 }) else {
            throw CheckFailure(description: "Silence produced nonzero bars")
        }

        store.prepare(file: tone)
        try await untilReady(store)
        let toneBands = store.bands(at: 0.8)
        guard toneBands.max() ?? 0 > 0.2, toneBands.filter({ $0 > 0.1 }).count < 10 else {
            throw CheckFailure(description: "MP3 tone did not produce localized frequency energy: \(toneBands)")
        }

        store.prepare(file: movie)
        try await untilReady(store)
        guard store.bands(at: 0.8).max() ?? 0 > 0.2 else {
            throw CheckFailure(description: "MP4 audio did not produce frequency energy")
        }

        store.prepare(file: pulse)
        try await untilReady(store)
        guard store.bands(at: 0.4).allSatisfy({ $0 == 0 }),
              store.bands(at: 1.5).max() ?? 0 > 0.2 else {
            throw CheckFailure(description: "Bars did not follow the silent and tonal regions of one file")
        }

        store.prepare(file: silent)
        guard !store.loading, store.bands(at: 0.8).allSatisfy({ $0 == 0 }) else {
            throw CheckFailure(description: "Cached silence was not restored")
        }
        print("PASS visualizer: MP3 silence, MP3 tone spectrum, MP4 audio, timeline response, cached file switch")
    }

    @MainActor
    private static func untilReady(_ store: AudioVisualizationStore) async throws {
        let deadline = Date().addingTimeInterval(20)
        while store.loading && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if store.loading { throw CheckFailure(description: "Audio analysis timed out") }
        if let error = store.error { throw CheckFailure(description: error) }
    }
}
