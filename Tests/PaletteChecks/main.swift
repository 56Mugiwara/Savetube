import AppKit
import Foundation
import SwiftUI

struct MediaFile { let url: URL; let kind: String = "MP3" }
struct Failure: Error { let message: String }

@main struct PaletteChecks {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SAVETUBE_TEST_ROOT"]!)
        let store = MediaPaletteStore.shared
        store.prepare(file: MediaFile(url: root.appendingPathComponent("artwork.mp3")), wallpaperURL: root.appendingPathComponent("wallpaper.png"))
        try await wait(store, source: "Artwork")
        guard let color = store.colors.first, let rgb = NSColor(color).usingColorSpace(.deviceRGB), rgb.redComponent > rgb.blueComponent * 2 else {
            throw Failure(message: "Embedded red artwork was not used")
        }
        store.prepare(file: MediaFile(url: root.appendingPathComponent("no-artwork.mp3")), wallpaperURL: root.appendingPathComponent("wallpaper.png"))
        try await wait(store, source: "Wallpaper")
        guard let color = store.colors.first, let rgb = NSColor(color).usingColorSpace(.deviceRGB), rgb.blueComponent > rgb.redComponent * 2 else {
            throw Failure(message: "Missing artwork did not fall back to blue wallpaper")
        }
        print("PASS palette: embedded artwork colors, artwork precedence, wallpaper fallback")
    }
    @MainActor static func wait(_ store: MediaPaletteStore, source: String) async throws {
        let deadline = Date().addingTimeInterval(12)
        while !store.sourceDescription.hasPrefix(source) && Date() < deadline { try await Task.sleep(nanoseconds: 30_000_000) }
        guard store.sourceDescription.hasPrefix(source) else { throw Failure(message: "Palette source did not become \(source)") }
    }
}
