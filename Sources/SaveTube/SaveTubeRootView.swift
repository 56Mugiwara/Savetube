import SwiftUI

private enum SaveTubePage: String, CaseIterable {
    case downloader = "Downloader"
    case player = "Player"
}

/// Downloading is the landing experience; the media library remains a separate workspace.
struct SaveTubeRootView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var engine: DownloadEngine
    @ObservedObject private var playback = PlaybackStore.shared
    @StateObject private var homeState = DownloadHomeState()
    @State private var page: SaveTubePage = .downloader
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if page == .downloader {
                DownloadHomeView(library: library, engine: engine, state: homeState) { file in
                    playback.play(file, queue: library.files)
                    page = .player
                }
            } else {
                NativeLibraryView(library: library, engine: engine, navigationBar: AnyView(bottomNavigation))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if page == .downloader { bottomNavigation }
        }
        .background(Color.black)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: page)
        .onReceive(NotificationCenter.default.publisher(for: .showSaveTubeDownloader)) { _ in page = .downloader }
        .onReceive(NotificationCenter.default.publisher(for: .showSaveTubePlayer)) { _ in page = .player }
    }
    private var bottomNavigation: some View {
            HStack {
                Spacer(minLength: 0)
                SegmentPill(values: SaveTubePage.allCases.map(\.rawValue), selection: Binding(
                    get: { page.rawValue },
                    set: { value in
                        guard let next = SaveTubePage(rawValue: value) else { return }
                        page = next
                    }
                ))
                .frame(width: 280, height: 48)
                .padding(6)
                .modifier(ClearGlassControl(radius: 32, panel: true))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
            .background(Color.black.opacity(0.68))
    }

}

extension Notification.Name {
    static let showSaveTubeDownloader = Notification.Name("SaveTube.showDownloader")
    static let showSaveTubePlayer = Notification.Name("SaveTube.showPlayer")
}
