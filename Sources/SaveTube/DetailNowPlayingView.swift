import AppKit
import AVKit
import SwiftUI

/// Expanded playback stays in the split view's detail column, never over its sidebar.
struct DetailNowPlayingView: View {
    @ObservedObject var store: PlaybackStore
    let onCollapse: () -> Void
    @ObservedObject private var palette = MediaPaletteStore.shared
    @ObservedObject private var spectrum = AudioVisualizationStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingQueue = false
    private var accent: Color { palette.colors.first ?? .white }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                VisualizerBackdrop(store: store, spectrum: spectrum, colors: palette.colors)
                VStack(spacing: 0) {
                    topBar.padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 8)
                    if showingQueue { queue }
                    else { playerContent(in: geometry.size) }
                }
            }
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Now Playing")
        .task(id: store.currentFile?.id) {
            if let file = store.currentFile { palette.prepare(file: file); spectrum.prepare(file: file) }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.88), value: showingQueue)
    }
    private var topBar: some View {
        HStack {
            Button(action: onCollapse) { Image(systemName: "chevron.down").frame(width: 40, height: 36) }
                .buttonStyle(ClearGlassButtonStyle()).help("Back to library").accessibilityLabel("Collapse player")
            Spacer()
            VStack(spacing: 3) {
                Text(showingQueue ? "Playing Next" : "Now Playing").font(.system(size: 12, weight: .semibold))
                Text(store.album.isEmpty ? "Your Library" : store.album).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Menu {
                if let file = store.currentFile {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                    Button("Open With Default App") { NSWorkspace.shared.open(file.url) }
                }
                Button("Stop Playback") { store.stop(); onCollapse() }
            } label: { Image(systemName: "ellipsis").frame(width: 40, height: 36) }
                .menuStyle(.borderlessButton).fixedSize().help("More playback actions")
        }
    }
    private func playerContent(in size: CGSize) -> some View {
        let compact = size.height < 730
        let coverSize = min(size.width - 70, compact ? 210 : min(390, size.height * 0.40))
        return ScrollView {
            VStack(spacing: compact ? 14 : 22) {
                if let file = store.currentFile {
                    if file.kind == "MP4" {
                        NativePlayerView(player: store.player).aspectRatio(16 / 9, contentMode: .fit)
                            .frame(maxWidth: 760).clipShape(RoundedRectangle(cornerRadius: 18))
                    } else {
                        MediaArtwork(file: file, size: max(140, coverSize))
                            .scaleEffect(store.isPlaying || reduceMotion ? 1 : 0.92)
                            .shadow(color: .black.opacity(0.38), radius: 28, y: 16)
                            .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.85), value: store.isPlaying)
                            .padding(.top, compact ? 8 : 16)
                    }
                    VStack(spacing: 18) {
                        HStack(alignment: .center, spacing: 18) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(store.title.isEmpty ? file.name : store.title).font(.system(size: compact ? 21 : 26, weight: .bold)).lineLimit(2)
                                Text(store.artist.isEmpty ? (file.kind == "MP4" ? "Video" : "Audio") : store.artist)
                                    .font(.system(size: compact ? 15 : 18)).foregroundStyle(.white.opacity(0.72)).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Button(action: store.toggleFavorite) {
                                Image(systemName: store.favoriteIDs.contains(file.id) ? "star.fill" : "star")
                                    .font(.system(size: 19)).frame(width: 42, height: 42)
                            }.buttonStyle(.plain).foregroundStyle(store.favoriteIDs.contains(file.id) ? accent : .white.opacity(0.8))
                                .accessibilityLabel(store.favoriteIDs.contains(file.id) ? "Remove favorite" : "Favorite track")
                        }
                        progress
                        HStack(spacing: compact ? 32 : 44) {
                            Button(action: store.previous) { Image(systemName: "backward.fill").font(.system(size: 25)).frame(width: 52, height: 52) }
                                .disabled(!store.canGoPrevious).accessibilityLabel("Previous track")
                            Button(action: store.toggle) { Image(systemName: store.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 40)).frame(width: 64, height: 60) }
                                .accessibilityLabel(store.isPlaying ? "Pause" : "Play")
                            Button(action: store.next) { Image(systemName: "forward.fill").font(.system(size: 25)).frame(width: 52, height: 52) }
                                .disabled(!store.canGoNext).accessibilityLabel("Next track")
                        }.buttonStyle(.plain).frame(maxWidth: .infinity)
                        AudioSpectrumView(store: store, spectrum: spectrum, colors: palette.colors)
                            .frame(height: compact ? 42 : 62).accessibilityLabel("Audio-reactive visualizer")
                        secondaryControls
                        if let error = store.error { Text(error).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center) }
                    }.frame(maxWidth: 540)
                } else {
                    Image(systemName: "music.note").font(.system(size: 50, weight: .ultraLight)).padding(.top, 70)
                    Text("Nothing Playing").font(.title2.bold())
                    Button("Return to Library", action: onCollapse).buttonStyle(.bordered)
                }
            }.padding(.horizontal, 32).padding(.bottom, 24).frame(maxWidth: .infinity)
        }.scrollIndicators(.hidden)
    }
    private var progress: some View {
        VStack(spacing: 6) {
            Slider(value: Binding(get: { min(store.currentTime, max(store.duration, 0)) }, set: { store.seek(to: $0) }), in: 0...max(store.duration, 1))
                .tint(.white).accessibilityLabel("Playback position")
            HStack {
                Text(time(store.currentTime))
                Spacer()
                Text("−" + time(max(0, store.duration - store.currentTime)))
            }.font(.system(size: 11, design: .rounded).monospacedDigit()).foregroundStyle(.white.opacity(0.62))
        }
    }
    private var secondaryControls: some View {
        VStack(spacing: 18) {
            HStack(spacing: 28) {
                Button(action: store.toggleShuffle) { Image(systemName: "shuffle").frame(width: 36, height: 32) }
                    .foregroundStyle(store.shuffleEnabled ? accent : .white.opacity(0.7)).accessibilityLabel(store.shuffleEnabled ? "Disable shuffle" : "Enable shuffle")
                Button(action: store.cycleRepeat) { Image(systemName: store.repeatMode == .one ? "repeat.1" : "repeat").frame(width: 36, height: 32) }
                    .foregroundStyle(store.repeatMode == .off ? .white.opacity(0.7) : accent).accessibilityLabel(store.repeatMode == .off ? "Repeat off" : store.repeatMode == .all ? "Repeat all" : "Repeat one")
                Spacer()
                PlaybackRoutePicker(player: store.player).frame(width: 34, height: 32).help("Choose audio output")
                Button { showingQueue = true } label: { Image(systemName: "list.bullet").frame(width: 36, height: 32) }.accessibilityLabel("Playing Next queue")
            }.font(.system(size: 18)).buttonStyle(.plain)
            HStack(spacing: 12) {
                Image(systemName: "speaker.fill").font(.system(size: 11))
                Slider(value: $store.volume, in: 0...1).tint(.white.opacity(0.75)).accessibilityLabel("Volume")
                Image(systemName: "speaker.wave.3.fill").font(.system(size: 14))
            }.foregroundStyle(.white.opacity(0.6)).frame(maxWidth: 300)
        }
    }
    private var queue: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button { showingQueue = false } label: { Label("Now Playing", systemImage: "chevron.left") }.buttonStyle(.plain).padding(.horizontal, 26)
            List {
                ForEach(store.queue) { file in
                    HStack(spacing: 12) {
                        MediaArtwork(file: file, size: 42)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(file.name).lineLimit(1).font(.system(size: 13, weight: .medium))
                            Text(file.id == store.currentFile?.id ? "Now Playing" : file.kind).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if file.id == store.currentFile?.id { Image(systemName: "waveform").foregroundStyle(accent) }
                        else { Button { store.removeFromQueue(file) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).help("Remove from queue") }
                    }.padding(.vertical, 6).contentShape(Rectangle())
                        .onTapGesture(count: 2) { store.play(file, queue: store.queue); showingQueue = false }
                }.onMove(perform: store.moveQueueItems)
            }.listStyle(.inset).scrollContentBackground(.hidden)
        }.padding(.top, 16)
    }
    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let value = Int(max(0, seconds)); return "\(value / 60):\(String(format: "%02d", value % 60))"
    }
}

private struct PlaybackRoutePicker: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView(); view.player = player
        view.setRoutePickerButtonColor(.white, for: .normal)
        return view
    }
    func updateNSView(_ view: AVRoutePickerView, context: Context) { view.player = player }
}

private struct AudioSpectrumView: View {
    @ObservedObject var store: PlaybackStore
    @ObservedObject var spectrum: AudioVisualizationStore
    let colors: [Color]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !store.isPlaying || reduceMotion)) { _ in
            let values = spectrum.bands(at: store.player.currentTime().seconds)
            Canvas { context, size in
                let spacing: CGFloat = 4
                let width = max(1, (size.width - CGFloat(values.count - 1) * spacing) / CGFloat(values.count))
                let gradient = Gradient(colors: colors.isEmpty ? [.white] : colors)
                for index in values.indices {
                    let height = max(3, CGFloat(values[index]) * size.height)
                    let rect = CGRect(x: CGFloat(index) * (width + spacing), y: (size.height - height) / 2, width: width, height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .linearGradient(gradient, startPoint: .init(x: 0, y: size.height), endPoint: .init(x: size.width, y: 0)))
                }
            }
        }.opacity(0.85)
    }
}

private struct VisualizerBackdrop: View {
    @ObservedObject var store: PlaybackStore
    @ObservedObject var spectrum: AudioVisualizationStore
    let colors: [Color]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            Color(white: 0.045)
            TimelineView(.animation(minimumInterval: 1 / 24, paused: !store.isPlaying || reduceMotion)) { _ in
                let bands = spectrum.bands(at: store.player.currentTime().seconds)
                Canvas { context, size in
                    context.addFilter(.blur(radius: 70))
                    let radius = max(size.width, size.height) * 0.72
                    for index in colors.indices.prefix(5) {
                        let strength = reduceMotion ? 0 : Double(bands[(index * 5) % max(1, bands.count)])
                        let x = size.width * (0.05 + CGFloat(index % 3) * 0.38) + CGFloat(strength) * 70
                        let y = size.height * (0.05 + CGFloat(index % 2) * 0.52) - CGFloat(strength) * 45
                        context.fill(Path(ellipseIn: CGRect(x: x - radius / 2, y: y - radius / 2, width: radius, height: radius)), with: .color(colors[index].opacity(0.35 + strength * 0.18)))
                    }
                }
            }
            Color.black.opacity(0.36)
        }.allowsHitTesting(false)
    }
}
