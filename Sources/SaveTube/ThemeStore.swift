import AppKit
import ImageIO
import UniformTypeIdentifiers
import Combine
import SwiftUI

/// Imports both legacy Matugen JSON and v4's { "color": "#..." } values.
@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()
    @Published var accent: Color = .white
    @Published var surface: Color = .black
    @Published var onSurface: Color = .white
    @Published var secondary: Color = .gray
    @Published var sourceDescription: String = "Monochrome"
    @Published var lastError: String?
    @Published private(set) var isGenerating = false
    @Published var glassBackground = false {
        didSet { defaults.set(glassBackground, forKey: "SaveTube.theme.glassBackground") }
    }
    @Published var regenerateOnWallpaperChange = false {
        didSet {
            defaults.set(regenerateOnWallpaperChange, forKey: "SaveTube.theme.regenerateOnWallpaperChange")
            // Enabling monitoring establishes a baseline; the Settings action
            // explicitly controls the first generation.
            lastWallpaperSignature = wallpaperSignature()
        }
    }

    private let defaults: UserDefaults
    private let paletteKey = "SaveTube.theme.palette"
    private let sourceKey = "SaveTube.theme.source"
    private var lastWallpaperSignature: String?
    private var subscriptions = Set<AnyCancellable>()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        glassBackground = defaults.bool(forKey: "SaveTube.theme.glassBackground")
        regenerateOnWallpaperChange = defaults.bool(forKey: "SaveTube.theme.regenerateOnWallpaperChange")
        if let saved = defaults.dictionary(forKey: paletteKey) as? [String: String],
           let primary = saved["primary"], Self.nsColor(primary) != nil {
            apply(saved, source: defaults.string(forKey: sourceKey) ?? "Saved palette", persist: false)
        }
        lastWallpaperSignature = wallpaperSignature()
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
            .sink { [weak self] _ in
                Task { @MainActor in self?.checkWallpaperChange() }
            }
            .store(in: &subscriptions)
    }

    func useMonochrome() {
        apply(["primary": "#FFFFFF", "surface": "#000000", "on_surface": "#F2F2F2", "secondary": "#8C8C8C"], source: "Monochrome")
    }

    func useWallpaper() {
        guard let url = wallpaperURL(), let image = NSImage(contentsOf: url),
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                  colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            lastError = "The current wallpaper could not be read. Import a Matugen JSON palette instead."
            return
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: 1, height: 1), from: .zero,
                   operation: .copy, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let sampled = bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB) else {
            lastError = "The wallpaper does not contain a readable color."
            return
        }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        sampled.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let tint = NSColor(calibratedHue: hue,
                           saturation: saturation < 0.03 ? 0 : min(0.65, max(0.25, saturation)),
                           brightness: min(0.95, max(0.72, brightness)), alpha: 1)
        apply(["primary": Self.hex(tint)], source: "Wallpaper Tint")
    }

    func importPalette(from url: URL) {
        do {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 10_000_000 else { throw ThemeError.invalidPalette }
            let palette = try Self.parsePalette(Data(contentsOf: url))
            apply(palette, source: "Matugen · \(url.deletingPathExtension().lastPathComponent)")
        } catch {
            lastError = "Could not import this palette: \(error.localizedDescription)"
        }
    }

    func generateWithMatugen(from imageURL: URL? = nil) {
        guard !isGenerating else { return }
        guard let executable = Self.matugenExecutable() else {
            lastError = "Matugen is not installed. Import a Matugen JSON palette or use Wallpaper Tint."
            return
        }
        guard let image = imageURL ?? wallpaperURL(), image.isFileURL,
              FileManager.default.isReadableFile(atPath: image.path) else {
            lastError = imageURL == nil
                ? "The current wallpaper could not be read. Choose an image or import a Matugen JSON palette instead."
                : "This image could not be read. Choose a readable local image file."
            return
        }
        let scopedAccess = image.startAccessingSecurityScopedResource()
        if imageURL == nil { lastWallpaperSignature = wallpaperSignature() }
        lastError = nil
        isGenerating = true
        Task {
            defer { if scopedAccess { image.stopAccessingSecurityScopedResource() } }
            let result = await Task.detached(priority: .userInitiated) {
                Result { try Self.runMatugen(executable: executable, wallpaper: image) }
            }.value
            isGenerating = false
            switch result {
            case .success(let palette):
                apply(palette, source: imageURL == nil ? "Matugen · Wallpaper" : "Matugen · \(image.deletingPathExtension().lastPathComponent)")
            case .failure(let error): lastError = error.localizedDescription
            }
            // If a wallpaper changed while the process was busy, generate the
            // newest palette once rather than losing that notification.
            if regenerateOnWallpaperChange { checkWallpaperChange() }
        }
    }

    func checkWallpaperChange() {
        guard regenerateOnWallpaperChange, !isGenerating else { return }
        let signature = wallpaperSignature()
        guard signature != lastWallpaperSignature else { return }
        lastWallpaperSignature = signature
        generateWithMatugen()
    }

    private func wallpaperSignature() -> String? {
        guard let url = wallpaperURL() else { return nil }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return url.standardizedFileURL.path + "|" + String(modified?.timeIntervalSince1970 ?? 0)
    }

    private func wallpaperURL() -> URL? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              let url = NSWorkspace.shared.desktopImageURL(for: screen),
              url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        return url
    }

    private func apply(_ palette: [String: String], source: String, persist: Bool = true) {
        accent = Color(nsColor: Self.nsColor(palette["primary"] ?? "") ?? .white)
        surface = Color(nsColor: Self.nsColor(palette["surface"] ?? "") ?? .black)
        onSurface = Color(nsColor: Self.nsColor(palette["on_surface"] ?? "") ?? .white)
        secondary = Color(nsColor: Self.nsColor(palette["secondary"] ?? "") ?? .gray)
        sourceDescription = source
        lastError = nil
        if persist {
            defaults.set(palette, forKey: paletteKey)
            defaults.set(source, forKey: sourceKey)
        }
    }

    nonisolated static func parsePalette(_ data: Data) throws -> [String: String] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ThemeError.invalidPalette
        }
        let colors = object["colors"] as? [String: Any] ?? object
        let dark = colors["dark"] as? [String: Any]
        func string(_ value: Any?) -> String? {
            if let value = value as? String { return value }
            if let value = value as? [String: Any] {
                return string(value["color"]) ?? string(value["hex"])
            }
            return nil
        }
        var result: [String: String] = [:]
        for key in ["primary", "secondary", "surface", "on_surface", "surface_container", "on_primary"] {
            let role = colors[key] as? [String: Any]
            let value = string(dark?[key]) ?? string(role?["dark"]) ?? string(colors[key])
            if let value, nsColor(value) != nil { result[key] = value }
        }
        guard result["primary"] != nil else { throw ThemeError.invalidPalette }
        return result
    }

    nonisolated private static func nsColor(_ value: String) -> NSColor? {
        var hex = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard [3, 6, 8].contains(hex.count), hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        // Matugen hex-alpha uses RRGGBBAA. The app uses an opaque accent.
        if hex.count == 8 { hex = String(hex.prefix(6)) }
        guard let rgb = UInt32(hex, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                       green: CGFloat((rgb >> 8) & 255) / 255,
                       blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }

    nonisolated private static func hex(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.deviceRGB) ?? .white
        return String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                      Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }

    nonisolated private static func matugenExecutable() -> URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/matugen").path
        if Bundle.main.bundleURL.pathExtension.lowercased() == "app" {
            return FileManager.default.isExecutableFile(atPath: bundled) ? URL(fileURLWithPath: bundled) : nil
        }
        var paths = [bundled, "/opt/homebrew/bin/matugen", "/usr/local/bin/matugen",
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cargo/bin/matugen").path]
        paths += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .filter { !$0.isEmpty }.map { String($0) + "/matugen" }
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    nonisolated private static func runMatugen(executable: URL, wallpaper: URL) throws -> [String: String] {
        // macOS dynamic wallpapers commonly use HEIC, which the standalone
        // generator may not decode. ImageIO normalizes a small palette sample.
        guard let source = CGImageSourceCreateWithURL(wallpaper as CFURL, nil),
              let sample = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { throw ThemeError.generationFailed }
        let normalized = FileManager.default.temporaryDirectory.appendingPathComponent("savetube-palette-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: normalized) }
        guard let destination = CGImageDestinationCreateWithURL(normalized as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw ThemeError.generationFailed }
        CGImageDestinationAddImage(destination, sample, nil)
        guard CGImageDestinationFinalize(destination) else { throw ThemeError.generationFailed }
        let process = Process()
        process.executableURL = executable
        // Official CLI: global --json <format>; --dry-run suppresses templates,
        // wallpaper changes, app reloads, and commands in the user's configuration.
        process.arguments = ["image", normalized.path, "--json", "hex", "--mode", "dark", "--dry-run", "--prefer", "saturation"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { throw ThemeError.generationFailed }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 45) {
            if process.isRunning { process.terminate() }
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ThemeError.generationFailed }
        return try parsePalette(data)
    }

    private enum ThemeError: LocalizedError {
        case invalidPalette, generationFailed
        var errorDescription: String? {
            switch self {
            case .invalidPalette: return "Expected a Matugen JSON palette with a valid dark primary hex color."
            case .generationFailed: return "Matugen could not generate a palette. Check that your Matugen build supports --json hex, or import a palette file."
            }
        }
    }
}
