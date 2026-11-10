import AVFoundation
import AppKit
import SwiftUI

/// Small cached artwork tile for library rows and the player.
struct MediaArtwork: View {
    let file: MediaFile
    var size: CGFloat = 44

    @State private var artwork: NSImage?

    private var radius: CGFloat { size >= 80 ? 16 : 8 }

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
        .task(id: file.url) {
            artwork = await ArtworkCache.image(for: file)
        }
    }
}

/// NSCache is thread-safe. Loading and decoding happen in a detached task so media
/// inspection never blocks SwiftUI's main actor.
private enum ArtworkCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for file: MediaFile) async -> NSImage? {
        let result = await Task.detached(priority: .utility) {
            let modified = (try? file.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
            let key = "\(file.url.standardizedFileURL.path)|\(modified)" as NSString
            if let cached = cache.object(forKey: key) { return ImageTransfer(image: cached) }

            let asset = AVURLAsset(url: file.url)
            let image: NSImage?
            if file.kind.uppercased() == "MP3" {
                image = await embeddedArtwork(in: asset)
            } else {
                image = await videoThumbnail(in: asset)
            }
            if let image { cache.setObject(image, forKey: key) }
            return ImageTransfer(image: image)
        }.value
        return result.image
    }

    private struct ImageTransfer: @unchecked Sendable { let image: NSImage? }

    private static func embeddedArtwork(in asset: AVURLAsset) async -> NSImage? {
        guard let metadata = try? await asset.load(.commonMetadata) else { return nil }
        for item in AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork) {
            if let data = try? await item.load(.dataValue), let image = NSImage(data: data) {
                return image
            }
        }
        return nil
    }

    private static func videoThumbnail(in asset: AVURLAsset) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)
        guard let (cgImage, _) = try? await generator.image(at: .zero) else { return nil }
        return NSImage(cgImage: cgImage, size: .zero)
    }
}
