import AppKit
import Foundation

@main struct ThemeChecks {
    @MainActor static func main() async throws {
        let variants = [
            ##"{"colors":{"dark":{"primary":"#aabbcc","surface":"#101010"}}}"##,
            ##"{"colors":{"primary":{"dark":"#aabbcc"},"surface":{"dark":"#101010"}}}"##,
            ##"{"colors":{"primary":{"dark":{"color":"#aabbccff"}},"surface":{"dark":{"color":"#101010ff"}}}}"##
        ]
        for sample in variants {
            let palette = try ThemeStore.parsePalette(Data(sample.utf8))
            precondition(palette["primary"]!.hasPrefix("#aabbcc"))
        }
        do {
            _ = try ThemeStore.parsePalette(Data(##"{"primary":"invalid"}"##.utf8))
            preconditionFailure("Invalid palette accepted")
        } catch {}

        let name = "SaveTube.ThemeChecks.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ThemeStore(defaults: defaults)
        store.glassBackground = true
        store.regenerateOnWallpaperChange = false
        let restored = ThemeStore(defaults: defaults)
        precondition(restored.glassBackground && !restored.regenerateOnWallpaperChange)

        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 256, bitsPerPixel: 32)!
        for y in 0..<64 {
            for x in 0..<64 {
                image.setColor(x < 32 ? NSColor(deviceRed: 0.1, green: 0.3, blue: 0.9, alpha: 1)
                    : (y < 32 ? NSColor(deviceRed: 0.95, green: 0.45, blue: 0.1, alpha: 1)
                              : NSColor(deviceRed: 0.85, green: 0.2, blue: 0.5, alpha: 1)), atX: x, y: y)
            }
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("SaveTube-theme-\(UUID()).png")
        try image.representation(using: .png, properties: [:])!.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        store.generateWithMatugen(from: file)
        let deadline = Date().addingTimeInterval(50)
        while store.isGenerating && Date() < deadline { try await Task.sleep(nanoseconds: 25_000_000) }
        precondition(!store.isGenerating, "Matugen did not finish")
        precondition(store.lastError == nil, store.lastError ?? "")
        precondition(store.sourceDescription.hasPrefix("Matugen · SaveTube-theme-"))
        let saved = defaults.dictionary(forKey: "SaveTube.theme.palette") as! [String: String]
        precondition(saved["primary"] != nil && saved["surface"] != nil)
        precondition(saved["primary"] != "#FFFFFF")
        print("Theme variants, settings persistence and real bundled Matugen generation passed (primary \(saved["primary"]!)).")
    }
}
