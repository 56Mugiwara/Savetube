import AppKit
import Foundation

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct ArtworkChecks {
    @MainActor
    static func main() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SAVETUBE_TEST_ROOT"]!)
        let media = MediaFile(url: root.appendingPathComponent("artwork.mp3"), kind: "MP3")
        let source = root.appendingPathComponent("cover.png")
        let cache = ArtworkCache.shared

        guard let row = await cache.image(for: media, maxPixelSize: 128, preferredURL: source),
              let player = await cache.image(for: media, maxPixelSize: 1024, preferredURL: source) else {
            throw CheckFailure(description: "ImageIO did not decode generated artwork")
        }
        let rowPixels = row.representations.map { max($0.pixelsWide, $0.pixelsHigh) }.max() ?? 0
        let playerPixels = player.representations.map { max($0.pixelsWide, $0.pixelsHigh) }.max() ?? 0
        guard rowPixels <= 128, playerPixels <= 1024, playerPixels > rowPixels else {
            throw CheckFailure(description: "Requested artwork sizes were not honored: row=\(rowPixels), player=\(playerPixels)")
        }

        let coalescedMedia = MediaFile(url: root.appendingPathComponent("coalesced.mp3"), kind: "MP3")
        let first = Task { await cache.image(for: coalescedMedia, maxPixelSize: 512, preferredURL: source) != nil }
        let second = Task { await cache.image(for: coalescedMedia, maxPixelSize: 512, preferredURL: source) != nil }
        for _ in 0..<8 { await Task.yield() }
        first.cancel()
        guard await second.value else {
            throw CheckFailure(description: "Canceling one coalesced consumer canceled its surviving consumer")
        }
        print("PASS artwork: 128/1024 pixel downsampling and shared-request cancellation")
    }
}
