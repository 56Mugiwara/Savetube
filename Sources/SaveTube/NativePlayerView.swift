import AVKit
import SwiftUI

/// AVKit's native macOS player surface, attached to the shared in-app AVPlayer.
struct NativePlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

struct MiniPlayer: View {
    @ObservedObject var store: PlaybackStore
    let onExpand: () -> Void

    var body: some View {
        if let file = store.currentFile {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Button(action: onExpand) {
                        HStack(spacing: 12) {
                            MediaArtwork(file: file, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .lineLimit(1)
                                Text(file.kind.uppercased() == "MP4" ? "Video" : "Audio")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show now playing: \(file.name)")

                    Button(action: store.previous) {
                        Image(systemName: "backward.end.fill")
                    }
                    .disabled(!store.canGoPrevious)
                    .accessibilityLabel("Previous track")

                    Button(action: store.toggle) {
                        Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 22)
                    }
                    .font(.system(size: 16))
                    .accessibilityLabel(store.isPlaying ? "Pause" : "Play")

                    Button(action: store.next) {
                        Image(systemName: "forward.end.fill")
                    }
                    .disabled(!store.canGoNext)
                    .accessibilityLabel("Next track")

                    Button(action: onExpand) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .accessibilityLabel("Expand player")
                }
                .buttonStyle(.plain)
                .font(.system(size: 14))

                Slider(value: Binding(
                    get: { min(store.currentTime, max(store.duration, 0)) },
                    set: { store.seek(to: $0) }
                ), in: 0...max(store.duration, 1))
                .controlSize(.mini)
                .accessibilityLabel("Playback position")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .modifier(ClearGlassControl(radius: 18, panel: true))
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }
}

struct NowPlayingView: View {
    @ObservedObject var store: PlaybackStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 22) {
            HStack {
                Text("Now Playing")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }

            if let file = store.currentFile {
                Group {
                    if file.kind.uppercased() == "MP4" {
                        NativePlayerView(player: store.player)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .background(.black)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else {
                        MediaArtwork(file: file, size: 220)
                    }
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 4) {
                    Text(file.name)
                        .font(.system(size: 21, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text(file.kind.uppercased() == "MP4" ? "Video" : "Audio")
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 5) {
                    Slider(value: Binding(
                        get: { min(store.currentTime, max(store.duration, 0)) },
                        set: { store.seek(to: $0) }
                    ), in: 0...max(store.duration, 1))
                    HStack {
                        Text(timeString(store.currentTime))
                        Spacer()
                        Text(timeString(store.duration))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 32) {
                    Button(action: store.previous) { Image(systemName: "backward.end.fill") }
                        .disabled(!store.canGoPrevious)
                        .accessibilityLabel("Previous track")
                    Button(action: store.toggle) {
                        Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 30)
                    }
                    .font(.system(size: 27))
                    .accessibilityLabel(store.isPlaying ? "Pause" : "Play")
                    Button(action: store.next) { Image(systemName: "forward.end.fill") }
                        .disabled(!store.canGoNext)
                        .accessibilityLabel("Next track")
                }
                .buttonStyle(.plain)
                .font(.system(size: 20))

                HStack(spacing: 12) {
                    Image(systemName: "speaker.fill")
                        .foregroundStyle(.secondary)
                    Slider(value: $store.volume, in: 0...1)
                        .accessibilityLabel("Volume")
                    Image(systemName: "speaker.wave.3.fill")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 220)

                if let error = store.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("Nothing Playing")
                        .font(.headline)
                    Text("Choose a file from your library.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(minWidth: 430, minHeight: 440)
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
