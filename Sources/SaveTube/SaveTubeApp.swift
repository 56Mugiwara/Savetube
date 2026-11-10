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
    @State<Bool> private var dragging = false
    @Namespace private var lensNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var spring: Animation? { reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.76) }
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width - 8
            let cell = width / CGFloat(values.count)
            let index = CGFloat(values.firstIndex(of: selection) ?? 0)
            let position = dragPosition ?? index * cell
            GlassGroup {
            ZStack(alignment: .leading) {
                SegmentLens(width: cell + (dragging && !reduceMotion ? 14 : 0),
                            height: geometry.size.height - 8 + (dragging && !reduceMotion ? 12 : 0),
                            namespace: lensNamespace, dragging: dragging, title: selection, small: small)
                    .animation(spring, value: dragging)
                    .offset(x: position + 4 - (dragging && !reduceMotion ? 7 : 0))
                    .allowsHitTesting(false)
                HStack(spacing: 0) {
                    ForEach(values, id: \.self) { value in
                        Button {
                            withAnimation(spring) { selection = value; dragPosition = nil }
                        } label: {
                            Text(value).font(.system(size: small ? 10 : 12, weight: .bold))
                                .foregroundStyle(selection == value ? Color.clear : Color(white: 0.72))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityAddTraits(selection == value ? [.isSelected] : [])
                    }
                }.padding(4)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(Capsule().fill(Color.white.opacity(0.055)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.06)).allowsHitTesting(false))
            .contentShape(Rectangle().inset(by: -5))
            .simultaneousGesture(DragGesture(minimumDistance: 2, coordinateSpace: .local)
                .onChanged { value in
                    if !dragging { withAnimation(spring) { dragging = true } }
                    let left = min(max(0, value.location.x - 4 - cell / 2), width - cell)
                    var transaction = Transaction(); transaction.animation = nil
                    withTransaction(transaction) {
                        dragPosition = left
                        let nearest = min(values.count - 1, max(0, Int((left / cell).rounded())))
                        if selection != values[nearest] { selection = values[nearest] }
                    }
                }
                .onEnded { _ in withAnimation(spring) { dragPosition = nil; dragging = false } })
            .animation(dragPosition == nil ? spring : nil, value: selection)
            }
        }
    }
}


extension Notification.Name { static let showSaveTubeSettings = Notification.Name("SaveTube.showSettings") }
