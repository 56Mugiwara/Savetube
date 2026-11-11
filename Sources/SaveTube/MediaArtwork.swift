import AVFoundation
import AppKit
import SwiftUI
import ImageIO

/// Small cached artwork tile for library rows and the player.
struct MediaArtwork: View {
    let file: MediaFile
    var size: CGFloat = 44
    @Environment(\.displayScale) private var displayScale
    @ObservedObject private var overrides = ArtworkOverrides.shared

    @State private var artwork: NSImage?

    private var radius: CGFloat { size >= 80 ? 16 : 8 }
    private var pixelBucket: Int {
        let target = max(1, size * max(1, displayScale))
        return [128, 256, 512, 1024, 2048].first(where: { CGFloat($0) >= target }) ?? 2048
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            } else {
                Image(systemName: file.kind.uppercased() == "MP4" ? "film" : "music.note")
                    .font(.system(size: size * 0.38, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .accessibilityHidden(true)
        .task(id: "\(file.url.standardizedFileURL.path)|\(pixelBucket)|\(overrides.cacheSignature(for: file))") {
            artwork = await ArtworkCache.shared.image(for: file, maxPixelSize: pixelBucket,
                                                       preferredURL: overrides.url(for: file))
        }
    }
}

/// NSCache is thread-safe. Loading and decoding happen in a detached task so media
/// inspection never blocks SwiftUI's main actor.
actor ArtworkCache {
    static let shared = ArtworkCache()
    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var consumers: [UUID: CheckedContinuation<NSImage?, Never>]
    }
    private var pending: [String: Flight] = [:]

    func image(for file: MediaFile, maxPixelSize: Int, preferredURL: URL?) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let modified = (try? file.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let preferredSignature: String = {
            guard let preferredURL else { return "none" }
            let values = try? preferredURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return "\(preferredURL.standardizedFileURL.path)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values?.fileSize ?? 0)"
        }()
        let stringKey = "\(file.url.standardizedFileURL.path)|\(modified)|\(preferredSignature)|\(maxPixelSize)"
        let key = stringKey as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let consumer = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if var flight = pending[stringKey] {
                    flight.consumers[consumer] = continuation
                    pending[stringKey] = flight
                } else {
                    let flightID = UUID()
                    let url = file.url
                    let kind = file.kind
                    let worker = Task.detached(priority: .utility) { [weak self] in
                        let image = await Self.decode(url: url, kind: kind, preferredURL: preferredURL,
                                                      maxPixelSize: maxPixelSize)
                        await self?.finish(key: stringKey, flightID: flightID, image: image)
                    }
                    pending[stringKey] = Flight(id: flightID, task: worker, consumers: [consumer: continuation])
                }
            }
        } onCancel: {
            Task { await self.cancelConsumer(for: stringKey, consumer: consumer) }
        }
    }

    private func cancelConsumer(for key: String, consumer: UUID) {
        guard var flight = pending[key], let continuation = flight.consumers.removeValue(forKey: consumer) else { return }
        continuation.resume(returning: nil)
        if flight.consumers.isEmpty {
            pending.removeValue(forKey: key)
            flight.task.cancel()
        } else {
            pending[key] = flight
        }
    }

    private func finish(key: String, flightID: UUID, image: NSImage?) {
        guard let flight = pending[key], flight.id == flightID else { return }
        pending.removeValue(forKey: key)
        if let image {
            let cost = max(1, image.representations.map { $0.pixelsWide * $0.pixelsHigh * 4 }.max() ?? Int(image.size.width * image.size.height * 4))
            cache.setObject(image, forKey: key as NSString, cost: cost)
        }
        for continuation in flight.consumers.values { continuation.resume(returning: image) }
    }

    private nonisolated static func decode(url: URL, kind: String, preferredURL: URL?, maxPixelSize: Int) async -> NSImage? {
        do { try await ArtworkDecodeLimiter.shared.acquire() }
        catch { return nil }
        guard !Task.isCancelled else {
            await ArtworkDecodeLimiter.shared.release()
            return nil
        }
        let decodedImage: NSImage?
        if let preferredURL, let preferred = image(at: preferredURL, maxPixelSize: maxPixelSize) {
            decodedImage = preferred
        } else if !Task.isCancelled {
            let asset = AVURLAsset(url: url)
            if kind.uppercased() == "MP3" {
                decodedImage = await embeddedArtwork(in: asset, maxPixelSize: maxPixelSize)
            } else {
                decodedImage = await videoThumbnail(in: asset, maxPixelSize: maxPixelSize)
            }
        } else {
            decodedImage = nil
        }
        await ArtworkDecodeLimiter.shared.release()
        return Task.isCancelled ? nil : decodedImage
    }

    private nonisolated static func image(at url: URL, maxPixelSize: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        if max(width, height) <= maxPixelSize, let original = NSImage(contentsOf: url) { return original }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return imageObject(from: image)
    }

    private nonisolated static func embeddedArtwork(in asset: AVURLAsset, maxPixelSize: Int) async -> NSImage? {
        guard let metadata = try? await asset.load(.commonMetadata) else { return nil }
        for item in AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork) {
            if let data = try? await item.load(.dataValue), let source = CGImageSourceCreateWithData(data as CFData, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let width = properties[kCGImagePropertyPixelWidth] as? Int,
               let height = properties[kCGImagePropertyPixelHeight] as? Int {
                // Preserve native detail when the embedded image is smaller than the requested bucket.
                if max(width, height) <= maxPixelSize { return NSImage(data: data) }
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                                                kCGImageSourceCreateThumbnailWithTransform: true]
                if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                    return imageObject(from: image)
                }
            }
        }
        return nil
    }

    private nonisolated static func videoThumbnail(in asset: AVURLAsset, maxPixelSize: Int) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        guard let (cgImage, _) = try? await generator.image(at: .zero) else { return nil }
        return Self.imageObject(from: cgImage)
    }

    private nonisolated static func imageObject(from image: CGImage) -> NSImage {
        let representation = NSBitmapImageRep(cgImage: image)
        let result = NSImage(size: NSSize(width: image.width, height: image.height))
        result.addRepresentation(representation)
        return result
    }
}

/// Fair, cancellable permit queue bounds memory-heavy ImageIO and AVFoundation decodes.
private actor ArtworkDecodeLimiter {
    static let shared = ArtworkDecodeLimiter()
    private let limit = 3
    private var active = 0
    private var order: [UUID] = []
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func acquire() async throws {
        try Task.checkCancellation()
        if active < limit { active += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = continuation
                order.append(id)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func release() {
        while !order.isEmpty {
            let id = order.removeFirst()
            if let continuation = waiters.removeValue(forKey: id) {
                continuation.resume()
                return
            }
        }
        active = max(0, active - 1)
    }

    private func cancelWaiter(_ id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        continuation.resume(throwing: CancellationError())
    }
}
