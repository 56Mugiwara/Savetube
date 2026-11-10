import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SaveTubeApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var engine = DownloadEngine()
    @StateObject private var playback = PlaybackStore.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("Savetube") {
            SaveTubeRootView(library: library, engine: engine)
                .frame(minWidth: 800, idealWidth: 900, minHeight: 680, idealHeight: 820)
                .preferredColorScheme(.dark)
                .onAppear { delegate.start(root: library.root, engine: engine) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 820)
        .commands {
            SidebarCommands()
            CommandMenu("Navigate") {
                Button("Downloader") { NotificationCenter.default.post(name: .showSaveTubeDownloader, object: nil) }.keyboardShortcut("1")
                Button("Player") { NotificationCenter.default.post(name: .showSaveTubePlayer, object: nil) }.keyboardShortcut("2")
            }
            CommandGroup(after: .help) {
                Button("Show Savetube Tour") {
                    NotificationCenter.default.post(name: .showSaveTubeTour, object: nil)
                }
            }
            CommandMenu("Playback") {
                Button("Play / Pause") { playback.toggle() }.disabled(playback.currentFile == nil)
                Button("Next") { playback.next() }.keyboardShortcut(.rightArrow).disabled(!playback.canGoNext)
                Button("Previous") { playback.previous() }.keyboardShortcut(.leftArrow).disabled(!playback.canGoPrevious)
                Divider()
                Button("Stop") { playback.stop() }.disabled(playback.currentFile == nil)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { NotificationCenter.default.post(name: .showSaveTubeSettings, object: nil) }.keyboardShortcut(",")
            }
            CommandGroup(after: .newItem) {
                Button("Cancel Download") { engine.cancel() }.keyboardShortcut(".").disabled(!engine.isRunning)
                Button("Retry Last Download") { engine.retry { library.refresh() } }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(engine.isRunning)
                Button("Refresh Library") { library.refresh() }.keyboardShortcut("r")
                Button("Import Existing History…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                    panel.message = "Choose the original SaveTube folder containing .Dmp3, .Dmp4, and .library.json."
                    if panel.runModal() == .OK, let folder = panel.url { library.importLegacy(from: folder) }
                }
            }
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private let helpers = HelperSupervisor()
    private var started = false
    private weak var engine: DownloadEngine?
    func start(root: URL, engine: DownloadEngine) { guard !started else { return }; started = true; self.engine = engine; helpers.start(root: root) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { engine?.cancel(); PlaybackStore.shared.stop(); helpers.stop() }
}

struct PillButton: View {
    let title: String
    var solid = false
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .bold)).frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(solid ? Color.black : Color(white: 0.95))
                .contentShape(Rectangle().inset(by: -7))
                .modifier(ClearGlassControl(prominent: solid))
        }.buttonStyle(GlassPressStyle()).onHover { hovered = $0 }
            .opacity(isEnabled ? 1 : 0.35)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hovered)
    }
}

struct SegmentPill: View {
    let values: [String]
    @Binding var selection: String
    var small = false
    @State<CGFloat?> private var dragPosition = nil
    @State private var dragging = false
    @State private var pressedSegment: String?
    @State private var rubberX: CGFloat = 0
    @State private var rubberY: CGFloat = 0
    @Namespace private var lensNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var spring: Animation? { reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.76) }
    private var lifted: Bool { pressedSegment != nil || dragging }
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width - 8
            let cell = width / CGFloat(values.count)
            let position = dragPosition ?? CGFloat(values.firstIndex(of: selection) ?? 0) * cell
            let growX: CGFloat = lifted && !reduceMotion ? 14 : 0
            let growY: CGFloat = lifted && !reduceMotion ? 12 : 0
            let stretchX = reduceMotion ? 0 : abs(rubberX) * 0.8
            let stretchY = reduceMotion ? 0 : abs(rubberY) * 0.8
            ZStack(alignment: .leading) {
                // Keep text OUTSIDE the glass container: the lens can move and
                // refract its backdrop without moving or sampling the labels.
                GlassGroup {
                    SegmentLens(width: cell + growX + stretchX,
                                height: geometry.size.height - 8 + growY + stretchY,
                                namespace: lensNamespace, dragging: lifted)
                }
                .animation(spring, value: lifted)
                .offset(x: position + 4 - (growX + stretchX) / 2 + (reduceMotion ? 0 : rubberX * 0.7),
                        y: reduceMotion ? 0 : rubberY * 0.6)
                .allowsHitTesting(false)
                .zIndex(0)
                HStack(spacing: 0) {
                    ForEach(values, id: \.self) { value in
                        Button {
                            withAnimation(spring) { selection = value; dragPosition = nil }
                        } label: {
                            Text(value).font(.system(size: small ? 10 : 12, weight: .bold))
                                .foregroundStyle(selection == value ? Color.white : Color(white: 0.72))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(SegmentPressStyle { down in
                            withAnimation(spring) {
                                if down { pressedSegment = value }
                                else if pressedSegment == value { pressedSegment = nil }
                            }
                        })
                        .accessibilityAddTraits(selection == value ? [.isSelected] : [])
                    }
                }.padding(4).compositingGroup().zIndex(1)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(Capsule().fill(Color.white.opacity(0.055)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.06)).allowsHitTesting(false))
            .contentShape(Rectangle().inset(by: -5))
            .simultaneousGesture(DragGesture(minimumDistance: 2, coordinateSpace: .local)
                .onChanged { value in
                    if !dragging { withAnimation(spring) { dragging = true } }
                    let rawLeft = value.location.x - 4 - cell / 2
                    let left = min(max(0, rawLeft), width - cell)
                    var transaction = Transaction(); transaction.animation = nil
                    withTransaction(transaction) {
                        dragPosition = left
                        rubberX = min(7, max(-7, (rawLeft - left) * 0.15))
                        rubberY = min(6, max(-6, value.translation.height * 0.10))
                        let nearest = min(values.count - 1, max(0, Int((left / cell).rounded())))
                        if selection != values[nearest] { selection = values[nearest] }
                    }
                }
                .onEnded { _ in
                    withAnimation(spring) { dragPosition = nil; dragging = false; rubberX = 0; rubberY = 0 }
                })
            .animation(dragPosition == nil ? spring : nil, value: selection)
        }
    }
}

/// Native button press state expands glass on mouse-down, before any drag.
private struct SegmentPressStyle: ButtonStyle {
    let changed: (Bool) -> Void
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .onChange(of: configuration.isPressed, perform: changed)
            .onDisappear { changed(false) }
    }
}


extension Notification.Name { static let showSaveTubeSettings = Notification.Name("SaveTube.showSettings") }
