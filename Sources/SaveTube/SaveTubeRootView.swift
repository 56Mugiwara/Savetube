import SwiftUI

private enum SaveTubePage: String, CaseIterable {
    case downloader = "Downloader"
    case player = "Player"
}

/// Downloading is the landing experience; the media library remains a separate workspace.
struct SaveTubeRootView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var engine: DownloadEngine
    @StateObject private var homeState = DownloadHomeState()
    @State private var page: SaveTubePage = .downloader
    @AppStorage("SaveTube.tourCompleted.v1") private var tourCompleted = false
    @State private var showTour = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ZStack {
                DownloadHomeView(library: library, engine: engine, state: homeState,
                                 isActive: page == .downloader && !showTour,
                                 switchToPlayer: showPlayer) { file in
                    PlaybackStore.shared.play(file, queue: library.files)
                    showPlayer()
                }
                .opacity(page == .downloader ? 1 : 0)
                .offset(x: reduceMotion || page == .downloader ? 0 : -14)
                .disabled(page != .downloader)
                .allowsHitTesting(page == .downloader)
                .accessibilityHidden(page != .downloader)

                NativeLibraryView(library: library, engine: engine,
                                  isActive: page == .player && !showTour,
                                  switchToDownloader: { page = .downloader })
                    .opacity(page == .player ? 1 : 0)
                    .offset(x: reduceMotion || page == .player ? 0 : 14)
                    .disabled(page != .player)
                    .allowsHitTesting(page == .player)
                    .accessibilityHidden(page != .player)
            }
            .disabled(showTour)
            .accessibilityHidden(showTour)

            if showTour {
                OnboardingTour(onFinish: finishTour)
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowChrome(downloaderVisible: page == .downloader))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: page)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: showTour)
        .onAppear { if !tourCompleted { page = .downloader; showTour = true } }
        .onReceive(NotificationCenter.default.publisher(for: .showSaveTubeDownloader)) { _ in if !showTour { page = .downloader } }
        .onReceive(NotificationCenter.default.publisher(for: .showSaveTubePlayer)) { _ in if !showTour { showPlayer() } }
        .onReceive(NotificationCenter.default.publisher(for: .showSaveTubeTour)) { _ in
            page = .downloader
            showTour = true
        }
    }

    private func showPlayer() {
        page = .player
    }

    private func finishTour() {
        tourCompleted = true
        showTour = false
    }
}

extension Notification.Name {
    static let showSaveTubeDownloader = Notification.Name("SaveTube.showDownloader")
    static let showSaveTubePlayer = Notification.Name("SaveTube.showPlayer")
    static let showSaveTubeTour = Notification.Name("SaveTube.showTour")
}
