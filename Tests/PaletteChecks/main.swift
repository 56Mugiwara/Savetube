import AppKit
import Foundation
import SwiftUI

struct Failure: Error { let message: String }

@main struct PaletteChecks {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SAVETUBE_TEST_ROOT"]!)
        let store = MediaPaletteStore.shared
        let artworkFile = MediaFile(url: root.appendingPathComponent("artwork.mp3"), kind: "MP3")
        let wallpaper = root.appendingPathComponent("wallpaper.png")
        store.prepare(file: artworkFile, wallpaperURL: wallpaper)
        try await wait(store, source: "Artwork")
        guard let color = store.colors.first, let rgb = NSColor(color).usingColorSpace(.deviceRGB), rgb.redComponent > rgb.blueComponent * 2 else {
            throw Failure(message: "Embedded red artwork was not used")
        }
        let normalized = store.colors.compactMap { NSColor($0).usingColorSpace(.deviceRGB) }
        let distinct = Set(normalized.map { String(format: "%.2f,%.2f,%.2f", $0.redComponent, $0.greenComponent, $0.blueComponent) })
        guard normalized.count == 5, distinct.count == 5,
              normalized.allSatisfy({ max($0.redComponent, max($0.greenComponent, $0.blueComponent)) >= 0.28 && max($0.redComponent, max($0.greenComponent, $0.blueComponent)) <= 0.67 }) else {
            throw Failure(message: "Bright single-color artwork did not produce five distinct dark palette roles")
        }

        await ArtworkOverrides.shared.set(imageURL: wallpaper, for: artworkFile)
        guard let savedOverride = ArtworkOverrides.shared.customURL(for: artworkFile),
              savedOverride != wallpaper, FileManager.default.fileExists(atPath: savedOverride.path) else {
            throw Failure(message: "Custom artwork was not persisted as a managed copy")
        }
        store.prepare(file: artworkFile, wallpaperURL: wallpaper)
        try await wait(store, source: "Artwork", matches: { $0.blueComponent > $0.redComponent * 2 })
        guard let color = store.colors.first, let rgb = NSColor(color).usingColorSpace(.deviceRGB), rgb.blueComponent > rgb.redComponent * 2 else {
            throw Failure(message: "Custom artwork did not take precedence over embedded artwork")
        }
        let invalidImage = root.appendingPathComponent("invalid-image.png")
        try Data("not an image".utf8).write(to: invalidImage)
        let savedBytes = try Data(contentsOf: savedOverride)
        await ArtworkOverrides.shared.set(imageURL: invalidImage, for: artworkFile)
        guard ArtworkOverrides.shared.lastError != nil,
              try Data(contentsOf: savedOverride) == savedBytes else {
            throw Failure(message: "Invalid replacement damaged the existing artwork or failed silently")
        }
        await ArtworkOverrides.shared.set(imageURL: wallpaper, for: artworkFile)
        guard ArtworkOverrides.shared.lastError == nil,
              ArtworkOverrides.shared.hasOverride(for: artworkFile) else {
            throw Failure(message: "A valid replacement did not atomically replace the saved artwork")
        }
        ArtworkOverrides.shared.clear(file: artworkFile)
        store.prepare(file: artworkFile, wallpaperURL: wallpaper)
        try await wait(store, source: "Artwork", matches: { $0.redComponent > $0.blueComponent * 2 })
        guard let color = store.colors.first, let rgb = NSColor(color).usingColorSpace(.deviceRGB), rgb.redComponent > rgb.blueComponent * 2 else {
            throw Failure(message: "Clearing custom artwork did not restore embedded artwork")
        }

        let noArtwork = MediaFile(url: root.appendingPathComponent("no-artwork.mp3"), kind: "MP3")
        store.prepare(file: noArtwork, wallpaperURL: wallpaper)
        try await wait(store, source: "Artwork", matches: { $0.greenComponent > $0.redComponent * 2 })
        guard let color = store.colors.first, let rgb = NSColor(color).usingColorSpace(.deviceRGB), rgb.greenComponent > rgb.redComponent * 2 else {
            throw Failure(message: "Adjacent sidecar artwork was not used")
        }
        let grayFile = MediaFile(url: root.appendingPathComponent("gray-cover.mp3"), kind: "MP3")
        await ArtworkOverrides.shared.set(imageURL: root.appendingPathComponent("grayscale.png"), for: grayFile)
        store.prepare(file: grayFile, wallpaperURL: wallpaper)
        try await wait(store, source: "Artwork · gray-cover")
        let grayColors = store.colors.compactMap { NSColor($0).usingColorSpace(.deviceRGB) }
        let grayLuminances = Set(grayColors.map { String(format: "%.2f", max($0.redComponent, max($0.greenComponent, $0.blueComponent))) })
        guard grayColors.count == 5, grayLuminances.count == 5,
              grayColors.allSatisfy({ abs($0.redComponent - $0.greenComponent) < 0.02 && abs($0.greenComponent - $0.blueComponent) < 0.02 }) else {
            throw Failure(message: "Grayscale artwork did not produce distinct neutral palette roles: \(grayColors.map { [$0.redComponent, $0.greenComponent, $0.blueComponent] })")
        }
        ArtworkOverrides.shared.clear(file: grayFile)
        for (name, shouldBeDark) in [("black", true), ("white", false)] {
            await ArtworkOverrides.shared.set(imageURL: root.appendingPathComponent("\(name).png"), for: grayFile)
            store.prepare(file: grayFile, wallpaperURL: wallpaper)
            try await wait(store, source: "Artwork · gray-cover", matches: { color in
                let peak = max(color.redComponent, max(color.greenComponent, color.blueComponent))
                return shouldBeDark ? peak < 0.4 : peak > 0.58
            })
            let colors = store.colors.compactMap { NSColor($0).usingColorSpace(.deviceRGB) }
            guard colors.count == 5, colors.allSatisfy({ abs($0.redComponent - $0.greenComponent) < 0.02 && abs($0.greenComponent - $0.blueComponent) < 0.02 }) else {
                throw Failure(message: "\(name.capitalized) artwork did not stay neutral")
            }
        }
        ArtworkOverrides.shared.clear(file: grayFile)
        try FileManager.default.removeItem(at: root.appendingPathComponent("no-artwork.png"))
        store.prepare(file: noArtwork, wallpaperURL: wallpaper)
        try await wait(store, source: "Wallpaper")
        guard let color = store.colors.first, let rgb = NSColor(color).usingColorSpace(.deviceRGB), rgb.blueComponent > rgb.redComponent * 2 else {
            throw Failure(message: "Missing artwork did not fall back to blue wallpaper")
        }
        print("PASS palette: embedded/custom/sidecar precedence, override persistence/reset, wallpaper fallback")
    }
    @MainActor static func wait(_ store: MediaPaletteStore, source: String, matches: ((NSColor) -> Bool)? = nil) async throws {
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            let color = store.colors.first.flatMap { NSColor($0).usingColorSpace(.deviceRGB) }
            if store.sourceDescription.hasPrefix(source), matches?(color ?? .black) ?? true { return }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        throw Failure(message: "Palette source did not become \(source)")
    }
}
