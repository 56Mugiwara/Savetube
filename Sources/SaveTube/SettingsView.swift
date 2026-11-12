import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var onClose: () -> Void = {}
    @AppStorage("SaveTube.backgroundOpacity") private var backgroundOpacity = 0.72
    @ObservedObject private var theme = ThemeStore.shared
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 24, weight: .light)).foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Settings").font(.system(size: 22, weight: .semibold))
                    Text("Glass, color, and the space around your music.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("Appearance").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 44, height: 44).modifier(ClearGlassControl()).contentShape(Capsule()) }.buttonStyle(GlassPressStyle()).help("Close Settings")
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Background").font(.system(size: 13, weight: .semibold))
                Picker("Background", selection: $theme.glassBackground) {
                    Text("Black").tag(false)
                    Text("Transparent Glass").tag(true)
                }.pickerStyle(.segmented).labelsHidden()
                Text("A lightly frosted, darkened desktop backdrop with clear glass controls. Native glass controls require macOS 26 or later.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if theme.glassBackground {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Background opacity").font(.system(size: 12))
                        Spacer()
                        Text("\(Int(backgroundOpacity * 100))%").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Slider(value: $backgroundOpacity, in: 0.45...0.95).tint(theme.accent)
                }
            }
            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Color palette").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if theme.isGenerating { ProgressView().controlSize(.small) }
                }
                Text(theme.sourceDescription).font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button("Monochrome") { theme.useMonochrome() }
                    Button("Wallpaper Tint") { theme.useWallpaper() }
                    Button("Import…") { importPalette() }
                }.buttonStyle(ClearGlassButtonStyle())
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Matugen generator").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 10) {
                    Button("From Wallpaper") { theme.generateWithMatugen() }
                    Button("Choose Image…") { chooseImage() }
                }.buttonStyle(ClearGlassButtonStyle()).disabled(theme.isGenerating)
                Toggle("Regenerate when the wallpaper changes", isOn: $theme.regenerateOnWallpaperChange)
                    .font(.system(size: 12)).disabled(theme.isGenerating)
                Text("Uses the bundled Matugen generator. Your wallpaper stays unchanged and Matugen templates are not run.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error = theme.lastError {
                    Text(error).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(26)
        }.scrollIndicators(.hidden).frame(width: 410).frame(maxHeight: .infinity)
        .preferredColorScheme(.dark)
        .modifier(ClearGlassControl(radius: 26, panel: true))
    }
    private func importPalette() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url { theme.importPalette(from: url) }
    }
    private func chooseImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url { theme.generateWithMatugen(from: url) }
    }
}

struct WindowBackdrop: NSViewRepresentable {
    var glass: Bool
    func makeNSView(context: Context) -> BackdropView { BackdropView() }
    func updateNSView(_ view: BackdropView, context: Context) {
        view.isHidden = !glass
        DispatchQueue.main.async {
            view.window?.isOpaque = !glass
            view.window?.backgroundColor = glass ? .clear : .black
        }
    }
    final class BackdropView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            // Frost only the window backdrop; controls keep their clear material.
            let blur = NSVisualEffectView(frame: bounds)
            blur.autoresizingMask = [.width, .height]
            blur.blendingMode = .behindWindow
            blur.material = .hudWindow
            blur.appearance = NSAppearance(named: .darkAqua)
            blur.state = .active
            blur.alphaValue = 0.75
            addSubview(blur)
            // Keep this as a backdrop, not a giant glass control. Glass belongs
            // to the controls above; full-window glass would wash out their text.
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
