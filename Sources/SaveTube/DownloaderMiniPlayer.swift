import SwiftUI

/// Playback stays available while the Downloader is in front of the library.
struct DownloaderMiniPlayer: View {
    let store: PlaybackStore
    @ObservedObject private var presentation = PlaybackPresentation.shared
    let onOpenPlayer: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @MainActor init(store: PlaybackStore? = nil, onOpenPlayer: @escaping () -> Void) {
        self.store = store ?? .shared
        self.onOpenPlayer = onOpenPlayer
    }

    var body: some View {
        Group {
            if let file = store.currentFile {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Button(action: onOpenPlayer) {
                        HStack(spacing: 10) {
                            MediaArtwork(file: file, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(store.title.isEmpty ? file.name : store.title)
                                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                Text(store.artist.isEmpty ? (file.kind.uppercased() == "MP4" ? "Video" : "Audio") : store.artist)
                                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(minWidth: 68, maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open player for \(file.name)")

                    transportButton("backward.end.fill", label: "Previous track", action: store.previous)
                        .disabled(!store.canGoPrevious)
                    transportButton(store.isPlaying ? "pause.fill" : "play.fill",
                                    label: store.isPlaying ? "Pause" : "Play", action: store.toggle)
                    transportButton("forward.end.fill", label: "Next track", action: store.next)
                        .disabled(!store.canGoNext)

                    Button(action: onOpenPlayer) {
                        Label("Open Player", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 12).frame(height: 44)
                            .modifier(ClearGlassControl()).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open full player")
                }

                MiniPlaybackProgress(store: store)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .modifier(ClearGlassControl(radius: 18, panel: true))
            .padding(.horizontal, 14).padding(.bottom, 10)
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.86), value: store.currentFile?.id)
    }

    private func transportButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 44, height: 44)
                .modifier(ClearGlassControl()).contentShape(Rectangle())
        }
        .buttonStyle(GlassPressStyle())
        .accessibilityLabel(label)
    }
}

/// Clock ticks redraw only the seek control, leaving artwork and transport
/// controls driven by structural playback changes.
private struct MiniPlaybackProgress: View {
    @ObservedObject var store: PlaybackStore

    var body: some View {
        Slider(value: Binding(
            get: { min(store.currentTime, max(store.duration, 0)) },
            set: { store.seek(to: $0) }
        ), in: 0...max(store.duration, 1))
            .controlSize(.small)
            .accessibilityLabel("Playback position")
    }
}
