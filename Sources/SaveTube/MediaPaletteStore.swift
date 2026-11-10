import AVFoundation
import AppKit
import Combine
import Foundation
import ImageIO
import SwiftUI

/// Builds a small dark palette from the artwork for the currently playing media.
/// When that media has no artwork, the active desktop wallpaper is sampled.
@MainActor
final class MediaPaletteStore: ObservableObject {
    static let shared = MediaPaletteStore()

    @Published private(set) var colors: [Color] = MediaPaletteStore.graphite
    @Published private(set) var sourceDescription = "Default palette"

    private var requestID = UUID()
    private var requestTask: Task<Void, Never>?

    private init() {}

    func prepare(file: MediaFile, wallpaperURL overrideWallpaperURL: URL? = nil) {
        requestTask?.cancel()
        let request = UUID()
        requestID = request
        let mediaURL = file.url
        let wallpaperURL = overrideWallpaperURL ?? Self.currentWallpaperURL()
        let key = Self.cacheKey(mediaURL: mediaURL, wallpaperURL: wallpaperURL)

        requestTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                await Self.palette(mediaURL: mediaURL, kind: file.kind,
                                   wallpaperURL: wallpaperURL, cacheKey: key)
            }.value
            guard !Task.isCancelled, let self, self.requestID == request else { return }
            if let result {
                self.colors = result.colors.map { Color(red: $0.r, green: $0.g, blue: $0.b) }
                self.sourceDescription = result.source
            } else {
                let theme = ThemeStore.shared
                self.colors = [theme.accent, theme.secondary, theme.surface, theme.onSurface, theme.accent]
                self.sourceDescription = "Theme colors"
            }
        }
    }

    private static let graphite: [Color] = [
        Color(red: 0.17, green: 0.19, blue: 0.22),
        Color(red: 0.24, green: 0.27, blue: 0.31),
        Color(red: 0.12, green: 0.14, blue: 0.17),
        Color(red: 0.30, green: 0.32, blue: 0.35),
        Color(red: 0.20, green: 0.22, blue: 0.25)
    ]

    private static func currentWallpaperURL() -> URL? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              let url = NSWorkspace.shared.desktopImageURL(for: screen),
              url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        return url
    }

    private static func cacheKey(mediaURL: URL, wallpaperURL: URL?) -> String {
        func signature(_ url: URL?) -> String {
            guard let url else { return "none" }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return "\(url.standardizedFileURL.path)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values?.fileSize ?? 0)"
        }
        return signature(mediaURL) + "|wallpaper:" + signature(wallpaperURL)
    }

    private struct RGB: Sendable {
        let r: Double
        let g: Double
        let b: Double
    }
    private struct Result: Sendable {
        let colors: [RGB]
        let source: String
    }
    nonisolated private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Result] = [:]

    nonisolated private static func palette(mediaURL: URL, kind: String, wallpaperURL: URL?, cacheKey: String) async -> Result? {
        let cached = cacheLock.withLock { cache[cacheKey] }
        if let cached { return cached }

        let media = await mediaImage(url: mediaURL, kind: kind)
        let result: Result?
        if let media {
            result = Result(colors: sample(media), source: "Artwork · \(mediaURL.deletingPathExtension().lastPathComponent)")
        } else if let wallpaperURL, let wallpaper = imageSource(url: wallpaperURL) {
            result = Result(colors: sample(wallpaper), source: "Wallpaper")
        } else {
            result = nil
        }
        if let result, !result.colors.isEmpty {
            cacheLock.withLock {
                cache[cacheKey] = result
                if cache.count > 32, let first = cache.keys.first { cache.removeValue(forKey: first) }
            }
        }
        return result
    }

    nonisolated private static func mediaImage(url: URL, kind: String) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        if kind.uppercased() == "MP3" {
            guard let metadata = try? await asset.load(.commonMetadata) else { return nil }
            for item in AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork) {
                if let data = try? await item.load(.dataValue),
                   let source = CGImageSourceCreateWithData(data as CFData, nil),
                   let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 256
                   ] as CFDictionary) {
                    return image
                }
            }
            return nil
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 256, height: 256)
        guard let (image, _) = try? await generator.image(at: .zero) else { return nil }
        return image
    }

    nonisolated private static func imageSource(url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary)
    }

    nonisolated private static func sample(_ image: CGImage) -> [RGB] {
        let width = 48, height = 48, bytesPerPixel = 4
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        let didDraw = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * bytesPerPixel, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didDraw else { return [] }

        var bins: [Int: (count: Int, r: Int, g: Int, b: Int, score: Double)] = [:]
        for i in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2]), a = Int(pixels[i + 3])
            guard a > 160 else { continue }
            let high = max(r, max(g, b)), low = min(r, min(g, b))
            let saturation = Double(high - low) / Double(max(high, 1))
            let brightness = Double(high) / 255
            let index = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4)
            // Saturation helps retain small vivid details; brightness weighting keeps
            // nearly black pixels from swallowing the palette.
            let score = 0.45 + saturation * 1.8 + min(brightness, 0.65) * 0.35
            if var bin = bins[index] {
                bin.count += 1; bin.r += r; bin.g += g; bin.b += b; bin.score += score
                bins[index] = bin
            } else { bins[index] = (1, r, g, b, score) }
        }
        let picked = bins.values.sorted { $0.score > $1.score }.prefix(5)
        return picked.map { bin in
            let r = Double(bin.r) / Double(bin.count) / 255
            let g = Double(bin.g) / Double(bin.count) / 255
            let b = Double(bin.b) / Double(bin.count) / 255
            // Keep accent hue while bringing every role into a dark UI range.
            let peak = max(r, max(g, b))
            let scale = peak > 0 ? min(0.72, max(0.42, 0.58 / peak)) : 1
            return RGB(r: min(1, r * scale), g: min(1, g * scale), b: min(1, b * scale))
        }
    }
}
