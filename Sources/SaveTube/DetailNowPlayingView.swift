import AppKit
import AVKit
import SwiftUI

/// Expanded playback stays in the split view's detail column, never over its sidebar.
struct DetailNowPlayingView: View {
    let store: PlaybackStore
    @ObservedObject private var presentation = PlaybackPresentation.shared
    var isActive = true
    let onCollapse: () -> Void
    @ObservedObject private var palette = MediaPaletteStore.shared
    @ObservedObject private var artworkOverrides = ArtworkOverrides.shared
    @ObservedObject private var spectrum = AudioVisualizationStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingQueue = false
    private var accent: Color { palette.colors.first ?? .white }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                VisualizerBackdrop(store: store, spectrum: spectrum, colors: palette.colors, isActive: isActive)
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
        .task(id: "\(store.currentFile?.id ?? "none")|\(artworkOverrides.revision)") {
            if let file = store.currentFile { palette.prepare(file: file); spectrum.prepare(file: file) }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.88), value: showingQueue)
    }
    private var topBar: some View {
        ZStack {
            HStack {
                Button(action: onCollapse) {
                    Image(systemName: "chevron.down").font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44).modifier(ClearGlassControl(radius: 22))
                        .padding(4).contentShape(Capsule())
                }.buttonStyle(GlassPressStyle()).help("Back to library").accessibilityLabel("Collapse player")
                Spacer(minLength: 0)
                Menu {
                    if let file = store.currentFile {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                        Button("Open With Default App") { NSWorkspace.shared.open(file.url) }
                    }
                    Button("Stop Playback") { store.stop(); onCollapse() }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                        .modifier(ClearGlassControl(radius: 22)).padding(4).contentShape(Capsule())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("More playback actions")
            }
            VStack(spacing: 3) {
                Text(showingQueue ? "Playing Next" : "Now Playing").font(.system(size: 12, weight: .semibold))
                Text(store.album.isEmpty ? "Your Library" : store.album).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity).allowsHitTesting(false)
        }
        .frame(height: 52)
    }
    private func playerContent(in size: CGSize) -> some View {
        let compact = size.height < 680 || size.width < 720
        let coverSize = min(max(0, size.width - 70), compact ? 190 : min(360, size.height * 0.38))
        return ScrollView {
            VStack(spacing: compact ? 14 : 22) {
                if let file = store.currentFile {
                    if file.kind == "MP4" {
                        NativePlayerView(player: store.player).aspectRatio(16 / 9, contentMode: .fit)
                            .frame(maxWidth: 760).clipShape(RoundedRectangle(cornerRadius: 18))
                    } else {
                        MediaArtwork(file: file, size: max(120, coverSize))
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
                                    .font(.system(size: 18)).frame(width: 44, height: 44)
                                    .modifier(ClearGlassControl(radius: 22)).contentShape(Capsule())
                            }.buttonStyle(GlassPressStyle()).foregroundStyle(store.favoriteIDs.contains(file.id) ? accent : .white.opacity(0.8))
                                .accessibilityLabel(store.favoriteIDs.contains(file.id) ? "Remove favorite" : "Favorite track")
                        }
                        progress
                        HStack(spacing: compact ? 32 : 44) {
                            Button(action: store.previous) { Image(systemName: "backward.fill").font(.system(size: 22)).frame(width: 44, height: 44).modifier(ClearGlassControl(radius: 22)).contentShape(Capsule()) }
                                .disabled(!store.canGoPrevious).accessibilityLabel("Previous track")
                            Button(action: store.toggle) { Image(systemName: store.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 28)).foregroundStyle(.black).frame(width: 56, height: 56).modifier(ClearGlassControl(radius: 28, prominent: true)).contentShape(Capsule()) }
                                .accessibilityLabel(store.isPlaying ? "Pause" : "Play")
                            Button(action: store.next) { Image(systemName: "forward.fill").font(.system(size: 22)).frame(width: 44, height: 44).modifier(ClearGlassControl(radius: 22)).contentShape(Capsule()) }
                                .disabled(!store.canGoNext).accessibilityLabel("Next track")
                        }.buttonStyle(GlassPressStyle()).frame(maxWidth: .infinity)
                        VStack(spacing: 4) {
                            AudioSpectrumView(store: store, spectrum: spectrum, colors: palette.colors, isActive: isActive)
                                .frame(height: compact ? 42 : 62).accessibilityLabel("Audio-reactive visualizer")
                            if let error = spectrum.error {
                                Text("Visualizer unavailable for this file").font(.caption2).foregroundStyle(.white.opacity(0.65)).help(error)
                            } else if spectrum.loading {
                                Text("Preparing visualizer…").font(.caption2).foregroundStyle(.white.opacity(0.65))
                            }
                        }
                        secondaryControls
                        if let error = store.error { Text(error).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center) }
                    }.frame(maxWidth: 600)
                } else {
                    Image(systemName: "music.note").font(.system(size: 50, weight: .ultraLight)).padding(.top, 70)
                    Text("Nothing Playing").font(.title2.bold())
                    Button(action: onCollapse) {
                        Text("Return to Library")
                            .padding(.horizontal, 18).frame(height: 44)
                            .modifier(ClearGlassControl()).contentShape(Capsule())
                    }.buttonStyle(GlassPressStyle())
                }
            }.padding(.horizontal, 24).padding(.bottom, 24).frame(maxWidth: 640).frame(maxWidth: .infinity)
        }.scrollIndicators(.hidden)
    }
    private var progress: some View {
        VStack(spacing: 6) {
            PlaybackProgressView(store: store, foreground: .white.opacity(0.62), sliderTint: .white)
        }
    }
    private var secondaryControls: some View {
        VStack(spacing: 18) {
            HStack(spacing: 28) {
                Button(action: store.toggleShuffle) { Image(systemName: "shuffle").frame(width: 44, height: 44).modifier(ClearGlassControl(radius: 22)).contentShape(Capsule()) }
                    .foregroundStyle(store.shuffleEnabled ? accent : .white.opacity(0.7)).accessibilityLabel(store.shuffleEnabled ? "Disable shuffle" : "Enable shuffle")
                Button(action: store.cycleRepeat) { Image(systemName: store.repeatMode == .one ? "repeat.1" : "repeat").frame(width: 44, height: 44).modifier(ClearGlassControl(radius: 22)).contentShape(Capsule()) }
                    .foregroundStyle(store.repeatMode == .off ? .white.opacity(0.7) : accent).accessibilityLabel(store.repeatMode == .off ? "Repeat off" : store.repeatMode == .all ? "Repeat all" : "Repeat one")
                Spacer()
                PlaybackRoutePicker(player: store.player).frame(width: 44, height: 44)
                    .modifier(ClearGlassControl(radius: 22)).contentShape(Capsule()).help("Choose audio output")
                Button { showingQueue = true } label: { Image(systemName: "list.bullet").frame(width: 44, height: 44).modifier(ClearGlassControl(radius: 22)).contentShape(Capsule()) }.accessibilityLabel("Playing Next queue")
            }.font(.system(size: 18)).buttonStyle(GlassPressStyle())
            HStack(spacing: 12) {
                Image(systemName: "speaker.fill").font(.system(size: 11))
                Slider(value: Binding(get: { store.volume }, set: { store.volume = $0 }), in: 0...1)
                    .tint(.white.opacity(0.75)).accessibilityLabel("Volume")
                Image(systemName: "speaker.wave.3.fill").font(.system(size: 14))
            }.foregroundStyle(.white.opacity(0.6)).frame(maxWidth: 300)
        }
    }
    private var queue: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button { showingQueue = false } label: {
                Label("Now Playing", systemImage: "chevron.left")
                    .padding(.horizontal, 16).frame(height: 44)
                    .modifier(ClearGlassControl()).contentShape(Capsule())
            }.buttonStyle(GlassPressStyle()).padding(.horizontal, 26)
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
                        else { Button { store.removeFromQueue(file) } label: { Image(systemName: "minus.circle").frame(width: 44, height: 44).modifier(ClearGlassControl()).contentShape(Capsule()) }.buttonStyle(GlassPressStyle()).help("Remove from queue") }
                    }.padding(.vertical, 6).contentShape(Capsule())
                        .onTapGesture(count: 2) { store.play(file, queue: store.queue); showingQueue = false }
                }.onMove(perform: store.moveQueueItems)
            }.listStyle(.inset).scrollContentBackground(.hidden)
        }.padding(.top, 16)
    }
}

/// Keeps the high frequency clock updates inside the small progress control.
private struct PlaybackProgressView: View {
    @ObservedObject var store: PlaybackStore
    let foreground: Color
    let sliderTint: Color

    var body: some View {
        VStack(spacing: 6) {
            Slider(value: Binding(get: { min(store.currentTime, max(store.duration, 0)) }, set: { store.seek(to: $0) }), in: 0...max(store.duration, 1))
                .tint(sliderTint).accessibilityLabel("Playback position")
            HStack {
                Text(time(store.currentTime))
                Spacer()
                Text("−" + time(max(0, store.duration - store.currentTime)))
            }.font(.system(size: 11, design: .rounded).monospacedDigit()).foregroundStyle(foreground)
        }
    }

    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let value = Int(max(0, seconds)); return "\(value / 60):\(String(format: "%02d", value % 60))"
    }
}

private struct PlaybackRoutePicker: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.player = player
        view.isRoutePickerButtonBordered = false
        view.setRoutePickerButtonColor(.white, for: .normal)
        view.setRoutePickerButtonColor(.white, for: .normalHighlighted)
        view.setRoutePickerButtonColor(.controlAccentColor, for: .active)
        view.setRoutePickerButtonColor(.controlAccentColor, for: .activeHighlighted)
        return view
    }
    func updateNSView(_ view: AVRoutePickerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

private struct AudioSpectrumView: View {
    @ObservedObject var store: PlaybackStore
    @ObservedObject var spectrum: AudioVisualizationStore
    let colors: [Color]
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let referenceDate = Date()
        let referenceTime = store.player.currentTime().seconds
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !isActive || !store.isPlaying || reduceMotion)) { timeline in
            // Project the sampled playhead onto this display frame. Keeping the clock
            // observation here also redraws after seeks without invalidating the player pane.
            let elapsed = store.isPlaying && !reduceMotion ? max(0, timeline.date.timeIntervalSince(referenceDate)) : 0
            let values = spectrum.bands(at: referenceTime + elapsed)
            Canvas(rendersAsynchronously: true) { context, size in
                let spacing: CGFloat = 4
                let width = max(1, (size.width - CGFloat(values.count - 1) * spacing) / CGFloat(values.count))
                let gradient = Gradient(colors: colors.isEmpty ? [.white] : colors)
                for index in values.indices {
                    let energy = pow(max(0, Double(values[index])), 0.76)
                    let height = max(3, CGFloat(min(1, energy * 1.18)) * size.height)
                    let rect = CGRect(x: CGFloat(index) * (width + spacing), y: (size.height - height) / 2, width: width, height: height)
                    let bar = Path(roundedRect: rect, cornerRadius: width / 2)
                    context.fill(bar, with: .linearGradient(gradient, startPoint: .init(x: 0, y: size.height), endPoint: .init(x: size.width, y: 0)))
                    context.fill(bar, with: .color(.white.opacity(0.38)))
                }
            }
        }.opacity(0.85)
    }
}

/// Soft colour fields cover the whole pane: no isolated discs or black empty corners.
private struct VisualizerBackdrop: View {
    let store: PlaybackStore
    @ObservedObject var spectrum: AudioVisualizationStore
    let colors: [Color]
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let palette = colors.isEmpty ? [Color(white: 0.22)] : colors
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !isActive || reduceMotion)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            let bands = spectrum.bands(at: store.player.currentTime().seconds)
            Canvas(opaque: true, rendersAsynchronously: true) { context, size in
                let bounds = Path(CGRect(origin: .zero, size: size))
                // A coloured foundation prevents the pools from revealing a black void.
                context.fill(bounds, with: .linearGradient(
                    Gradient(colors: [palette[0], palette[palette.count / 2], palette[palette.count - 1]]),
                    startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
                for index in 0..<min(4, palette.count) {
                    let phase = Double(index) * 2.1
                    let energy = reduceMotion ? 0 : Double(bands[(index * 5) % max(1, bands.count)])
                    let x = 0.5 + sin(time * 0.075 + phase) * 0.44
                    let y = 0.5 + cos(time * 0.063 + phase * 1.2) * 0.42
                    let radius = max(size.width, size.height) * CGFloat(0.82 + sin(time * 0.09 + phase) * 0.08 + energy * 0.05)
                    let gradient = Gradient(stops: [
                        .init(color: palette[index].opacity(0.90), location: 0),
                        .init(color: palette[index].opacity(0.48), location: 0.44),
                        .init(color: palette[index].opacity(0), location: 1)
                    ])
                    context.fill(bounds, with: .radialGradient(gradient,
                        center: CGPoint(x: size.width * x, y: size.height * y),
                        startRadius: 0, endRadius: radius))
                }
                // Keep white labels readable without dimming the entire colour canvas.
                context.fill(bounds, with: .linearGradient(
                    Gradient(colors: [.black.opacity(0.08), .black.opacity(0.26)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            }
        }.allowsHitTesting(false)
    }
}
