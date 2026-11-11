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
        let preferredArtworkURL = ArtworkOverrides.shared.url(for: file)
        let overridesRevision = ArtworkOverrides.shared.revision
        let key = Self.cacheKey(mediaURL: mediaURL, wallpaperURL: wallpaperURL,
                                preferredArtworkURL: preferredArtworkURL, overridesRevision: overridesRevision)

        requestTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) {
                try await Self.palette(mediaURL: mediaURL, kind: file.kind,
                                       preferredArtworkURL: preferredArtworkURL,
                                       wallpaperURL: wallpaperURL, cacheKey: key)
            }
            let result: Result?
            do {
                result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
            } catch {
                return
            }
            guard !Task.isCancelled, let self, self.requestID == request else { return }
            if let result {
                self.colors = result.colors.map { Color(red: $0.r, green: $0.g, blue: $0.b) }
                self.sourceDescription = result.source
            } else {
                let theme = ThemeStore.shared
                // onSurface is commonly white and becomes an oversized bright blob
                // in the visualizer. Keep the fallback colors in the dark theme range.
                let fallback = [theme.accent, theme.secondary, theme.surface, theme.accent, theme.secondary]
                self.colors = fallback.map { Self.darkThemeColor($0) }
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

    private static func cacheKey(mediaURL: URL, wallpaperURL: URL?, preferredArtworkURL: URL?, overridesRevision: Int) -> String {
        func signature(_ url: URL?) -> String {
            guard let url else { return "none" }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return "\(url.standardizedFileURL.path)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values?.fileSize ?? 0)"
        }
        return signature(mediaURL) + "|artwork:" + signature(preferredArtworkURL) + "|revision:\(overridesRevision)|wallpaper:" + signature(wallpaperURL)
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

    nonisolated private static func palette(mediaURL: URL, kind: String, preferredArtworkURL: URL?, wallpaperURL: URL?, cacheKey: String) async throws -> Result? {
        try Task.checkCancellation()
        let cached = cacheLock.withLock { cache[cacheKey] }
        if let cached { return cached }

        let media = try await mediaImage(url: mediaURL, kind: kind, preferredArtworkURL: preferredArtworkURL)
        try Task.checkCancellation()
        let result: Result?
        if let media {
            let colors = sample(media)
            try Task.checkCancellation()
            result = Result(colors: colors, source: "Artwork · \(mediaURL.deletingPathExtension().lastPathComponent)")
        } else if let wallpaperURL, let wallpaper = imageSource(url: wallpaperURL) {
            try Task.checkCancellation()
            let colors = sample(wallpaper)
            try Task.checkCancellation()
            result = Result(colors: colors, source: "Wallpaper")
        } else {
            result = nil
        }
        try Task.checkCancellation()
        if let result, !result.colors.isEmpty {
            cacheLock.withLock {
                cache[cacheKey] = result
                if cache.count > 32, let first = cache.keys.first { cache.removeValue(forKey: first) }
            }
        }
        return result
    }

    nonisolated private static func mediaImage(url: URL, kind: String, preferredArtworkURL: URL?) async throws -> CGImage? {
        try Task.checkCancellation()
        if let preferredArtworkURL {
            let image = imageSource(url: preferredArtworkURL)
            try Task.checkCancellation()
            if let image { return image }
        }
        let asset = AVURLAsset(url: url)
        if kind.uppercased() == "MP3" {
            guard let metadata = try? await asset.load(.commonMetadata) else {
                try Task.checkCancellation()
                return nil
            }
            try Task.checkCancellation()
            for item in AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork) {
                try Task.checkCancellation()
                if let data = try? await item.load(.dataValue) {
                    try Task.checkCancellation()
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 256
                          ] as CFDictionary) else { continue }
                    try Task.checkCancellation()
                    return image
                }
            }
            return nil
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 256, height: 256)
        let generated = try? await withTaskCancellationHandler {
            try await generator.image(at: .zero)
        } onCancel: {
            generator.cancelAllCGImageGeneration()
        }
        try Task.checkCancellation()
        guard let (image, _) = generated else { return nil }
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

        var bins: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
        for i in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2]), a = Int(pixels[i + 3])
            guard a > 160 else { continue }
            let index = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4)
            if var bin = bins[index] {
                bin.count += 1; bin.r += r; bin.g += g; bin.b += b
                bins[index] = bin
            } else { bins[index] = (1, r, g, b) }
        }
        let candidates: [Candidate] = bins.values.map { bin in
            let count = Double(bin.count)
            let red = Double(bin.r) / count / 255
            let green = Double(bin.g) / count / 255
            let blue = Double(bin.b) / count / 255
            let color = RGB(r: red, g: green, b: blue)
            return Candidate(rgb: color, count: bin.count, hsv: hsv(color))
        }.sorted { a, b in
            // Population leads; a modest saturation bonus lets meaningful accents
            // survive without allowing tiny specks to dominate the palette.
            Double(a.count) * (0.8 + a.hsv.s * 0.45) > Double(b.count) * (0.8 + b.hsv.s * 0.45)
        }

        var picked: [(rgb: RGB, hsv: HSV)] = []
        for candidate in candidates {
            guard picked.allSatisfy({ distance(candidate.hsv, $0.hsv) >= 0.16 }) else { continue }
            picked.append((candidate.rgb, candidate.hsv))
            if picked.count == 5 { break }
        }

        // A single-color or grayscale cover still needs several useful roles. Add
        // luminance variants of its strongest colors rather than repeating bins.
        if picked.isEmpty { picked.append((RGB(r: 0.25, g: 0.25, b: 0.25), HSV(h: 0, s: 0, v: 0.25))) }
        let seeds = picked
        let variants = [0.42, 0.60, 0.31, 0.52, 0.36]
        while picked.count < 5 {
            let index = picked.count - seeds.count
            let seed = seeds[index % seeds.count]
            let hsv = HSV(h: seed.hsv.h, s: seed.hsv.s, v: variants[index % variants.count])
            picked.append((rgb(hsv), hsv))
        }
        return picked.map { normalize($0.hsv) }
    }

    private struct HSV { let h: Double; let s: Double; let v: Double }
    private struct Candidate { let rgb: RGB; let count: Int; let hsv: HSV }

    nonisolated private static func hsv(_ color: RGB) -> HSV {
        let high = max(color.r, max(color.g, color.b)), low = min(color.r, min(color.g, color.b))
        let delta = high - low
        let hue: Double
        if delta == 0 { hue = 0 }
        else if high == color.r { hue = ((color.g - color.b) / delta).truncatingRemainder(dividingBy: 6) / 6 }
        else if high == color.g { hue = ((color.b - color.r) / delta + 2) / 6 }
        else { hue = ((color.r - color.g) / delta + 4) / 6 }
        return HSV(h: hue < 0 ? hue + 1 : hue, s: high == 0 ? 0 : delta / high, v: high)
    }

    nonisolated private static func rgb(_ color: HSV) -> RGB {
        let h = (color.h - floor(color.h)) * 6
        let i = Int(floor(h)), f = h - floor(h)
        let p = color.v * (1 - color.s), q = color.v * (1 - color.s * f), t = color.v * (1 - color.s * (1 - f))
        switch i % 6 {
        case 0: return RGB(r: color.v, g: t, b: p)
        case 1: return RGB(r: q, g: color.v, b: p)
        case 2: return RGB(r: p, g: color.v, b: t)
        case 3: return RGB(r: p, g: q, b: color.v)
        case 4: return RGB(r: t, g: p, b: color.v)
        default: return RGB(r: color.v, g: p, b: q)
        }
    }

    nonisolated private static func distance(_ a: HSV, _ b: HSV) -> Double {
        let hueDelta = min(abs(a.h - b.h), 1 - abs(a.h - b.h))
        return sqrt(pow(hueDelta * min(a.s, b.s) * 2, 2) + pow((a.s - b.s) * 0.65, 2) + pow((a.v - b.v) * 0.25, 2))
    }

    nonisolated private static func normalize(_ color: HSV) -> RGB {
        let saturation = color.s < 0.08 ? 0 : min(0.82, max(0.38, color.s))
        let brightness = min(0.66, max(0.29, color.v))
        return rgb(HSV(h: color.h, s: saturation, v: brightness))
    }

    private static func darkThemeColor(_ color: Color) -> Color {
        let nsColor = NSColor(color).usingColorSpace(.deviceRGB) ?? .gray
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        nsColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let dark = NSColor(calibratedHue: hue, saturation: saturation < 0.08 ? 0 : min(0.82, max(0.38, saturation)),
                           brightness: min(0.66, max(0.29, brightness)), alpha: 1)
        return Color(dark)
    }
}
