import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum LibraryDestination: Hashable {
    case all, music, videos, recent, favorites, folder(String)
    var title: String {
        switch self {
        case .all: return "Library"
        case .music: return "Music"
        case .videos: return "Videos"
        case .recent: return "Recently Added"
        case .favorites: return "Favorites"
        case .folder(let name): return name
        }
    }
}

/// Music-inspired media navigation, translated into native macOS split-view conventions.
struct NativeLibraryView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var engine: DownloadEngine
    var isActive = true
    var switchToDownloader: (() -> Void)? = nil
    // PlaybackPresentation excludes the 4 Hz clock publisher, so a playing
    // track does not rebuild the whole library list on every tick.
    @ObservedObject private var playbackPresentation = PlaybackPresentation.shared
    private var playback: PlaybackStore { PlaybackStore.shared }
    @ObservedObject private var artworkOverrides = ArtworkOverrides.shared
    @ObservedObject private var theme = ThemeStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("SaveTube.backgroundOpacity") private var backgroundOpacity = 0.72
    @State private var destination: LibraryDestination? = .all
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var selection: String?
    @State private var query = ""
    @State private var showDownloads = false
    @State private var showSettings = false
    @State private var showPlayer = false
    @State private var naming = false
    @State private var newName = ""
    @State private var renameFolder: String?
    @State private var renameFile: MediaFile?
    @State private var deleting = false
    @State private var deleteFile: MediaFile?
    @State private var deleteFolder: String?
    @State private var deleteContents = false
    private var motion: Animation? { reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.86) }
    private var accent: Color { theme.sourceDescription == "Monochrome" ? Color(red: 0.98, green: 0.18, blue: 0.29) : theme.accent }
    private var activeFolder: String? { if case .folder(let name) = destination { return name }; return nil }
    private var selectedFile: MediaFile? { visibleFiles.first { $0.id == selection } }
    private var visibleFiles: [MediaFile] {
        let filtered = library.files.filter { file in
            let matchesDestination: Bool
            switch destination ?? .all {
            case .music: matchesDestination = file.kind == "MP3"
            case .videos: matchesDestination = file.kind == "MP4"
            case .favorites: matchesDestination = playback.favoriteIDs.contains(file.id)
            case .folder(let name): matchesDestination = library.assignments[file.id] == name
            default: matchesDestination = true
            }
            return matchesDestination && (query.isEmpty || file.name.localizedCaseInsensitiveContains(query))
        }
        if destination == .recent {
            return filtered.sorted {
                let first = (try? $0.url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let second = (try? $1.url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return first > second
            }
        }
        return filtered
    }
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 175, ideal: 205, max: 260)
        } detail: {
            ZStack {
                if showPlayer {
                    DetailNowPlayingView(store: playback, isActive: isActive) { withAnimation(motion) { showPlayer = false } }
                        .padding(.top, 62)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom))
                        .zIndex(1)
                } else {
                    detail.safeAreaInset(edge: .bottom, spacing: 0) {
                        if playback.currentFile != nil {
                            MiniPlayer(store: playback) { withAnimation(motion) { showPlayer = true } }
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .transition(.opacity).zIndex(0)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                .animation(motion, value: showPlayer)
        }
        .background(LibraryKeyboard(onMove: { _ in false }, onOpen: {
            guard isActive && !naming && !deleting && !showSettings && !showDownloads,
                  let selectedFile, visibleFiles.contains(where: { $0.id == selectedFile.id }) else { return false }
            playback.play(selectedFile, queue: visibleFiles)
            return true
        }, onEscape: { false }, onSpace: {
            guard isActive && !naming && !deleting && !showSettings && !showDownloads,
                  library.lastError == nil, playback.currentFile != nil else { return false }
            playback.toggle()
            return true
        }).frame(width: 0, height: 0))
        .tint(accent)
        .background {
            if theme.glassBackground {
                WindowBackdrop(glass: true).overlay(Color.black.opacity(backgroundOpacity * 0.4))
            }
            else { Color(nsColor: .windowBackgroundColor) }
        }
        .overlay { settingsPanel }
        .sheet(isPresented: $naming) { namingPanel }
        .sheet(isPresented: $deleting) { deletionPanel }
        .onReceive(NotificationCenter.default.publisher(for: .showSaveTubeSettings)) { _ in if isActive { showSettings = true } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in if isActive { library.refresh() } }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in if isActive && NSApplication.shared.isActive { library.refresh() } }
        .onChange(of: destination) { _ in selection = nil; showPlayer = false }
        .onChange(of: query) { _ in selection = nil }
        .animation(motion, value: playback.currentFile?.id)
        .animation(motion, value: showSettings)
        .alert("Library", isPresented: Binding(get: { isActive && library.lastError != nil }, set: { if !$0 { library.lastError = nil } })) {
            Button("OK") { library.lastError = nil }
        } message: { Text(library.lastError ?? "") }
        .ignoresSafeArea(.container, edges: .top)
    }
    private var sidebar: some View {
        List(selection: $destination) {
            Section {
                Label("Recently Added", systemImage: "clock").tag(LibraryDestination.recent)
                Label("All Media", systemImage: "square.stack").tag(LibraryDestination.all)
                Label("Music", systemImage: "music.note").tag(LibraryDestination.music)
                Label("Videos", systemImage: "play.rectangle").tag(LibraryDestination.videos)
                Label("Favorites", systemImage: "star").tag(LibraryDestination.favorites)
            } header: { Text("Library") }
            Section {
                ForEach(library.folders, id: \.self) { folder in
                    Label(folder, systemImage: "music.note.list")
                        .tag(LibraryDestination.folder(folder))
                        .contextMenu {
                            Button("Play") { playFolder(folder) }
                            Button("Import Music…") { importFiles(into: folder) }
                            Divider()
                            Button("Rename…") { beginName(folder: folder) }
                            Button("Delete Folder…", role: .destructive) { requestDelete(folder: folder) }
                        }
                        .onDrop(of: [.fileURL, .plainText], isTargeted: nil) { drop($0, into: folder) }
                }
                Button { beginName() } label: { Label("New Folder", systemImage: "plus") }.buttonStyle(.plain)
            } header: { Text("Folders") }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .navigationTitle("MediaFetch")
        .padding(.top, 62)
        .background(Color.black.opacity(backgroundOpacity * 0.4))
        .safeAreaInset(edge: .bottom) {
            HStack {
                Image(systemName: "arrow.down.circle").foregroundStyle(accent)
                Text("\(library.files.count) saved \(library.files.count == 1 ? "item" : "items")").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.padding(16)
        }
    }
    private var detail: some View {
        VStack(spacing: 0) {
            toolbarControls
            header
            if !engine.status.isEmpty { downloadStatus }
            if visibleFiles.isEmpty { emptyLibrary }
            else { mediaList }
            if let selectedFile {
                HStack {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(selectedFile.url.deletingLastPathComponent().path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 28).padding(.vertical, 10)
            }
        }
        .background(theme.glassBackground ? Color.black.opacity(backgroundOpacity) : Color(nsColor: .windowBackgroundColor))
        .navigationTitle((destination ?? .all).title)
    }
    private var toolbarControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                sidebarToggle
                searchField(minimumWidth: 80)
                importButton
                deleteButton
                downloadButton
                settingsButton
            }

            HStack(spacing: 8) {
                sidebarToggle
                searchField(minimumWidth: 70)
                actionsMenu
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 190)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }
    private var sidebarToggle: some View {
        Button {
            columnVisibility = columnVisibility == .all ? .detailOnly : .all
        } label: {
            Image(systemName: columnVisibility == .all ? "sidebar.left" : "sidebar.right")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .modifier(ClearGlassControl(radius: 22))
        .buttonStyle(GlassPressStyle())
        .help(columnVisibility == .all ? "Hide Sidebar" : "Show Sidebar")
    }
    private func searchField(minimumWidth: CGFloat) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $query).textFieldStyle(.plain)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .help("Clear Search")
            }
        }
        .padding(.horizontal, 14)
        .frame(minWidth: minimumWidth, maxWidth: .infinity, minHeight: 44, maxHeight: 44)
        .modifier(ClearGlassControl(radius: 22))
    }
    private var importButton: some View {
        Button { importFiles(into: activeFolder) } label: {
            Image(systemName: "square.and.arrow.down").font(.system(size: 15)).frame(width: 44, height: 44)
        }
        .modifier(ClearGlassControl(radius: 22)).buttonStyle(GlassPressStyle())
        .help("Import Media").disabled(library.isImporting)
    }
    private var deleteButton: some View {
        Button { requestDelete(file: selectedFile, folder: selectedFile == nil ? activeFolder : nil) } label: {
            Image(systemName: "trash").font(.system(size: 15)).frame(width: 44, height: 44)
        }
        .modifier(ClearGlassControl(radius: 22)).buttonStyle(GlassPressStyle())
        .help("Delete Selected Media")
        .disabled(selectedFile == nil && activeFolder == nil)
    }
    private var downloadButton: some View {
        Button { showDownloads.toggle() } label: {
            Image(systemName: engine.isRunning ? "arrow.down.circle.fill" : "arrow.down.circle")
                .font(.system(size: 15)).frame(width: 44, height: 44)
        }
        .modifier(ClearGlassControl(radius: 22)).buttonStyle(GlassPressStyle())
        .help("Download from a link")
        .popover(isPresented: $showDownloads, arrowEdge: .top) {
            DownloadComposer(engine: engine, library: library) { showDownloads = false }.frame(width: 440)
        }
    }
    private var settingsButton: some View {
        Button { withAnimation(motion) { showSettings = true } } label: {
            Image(systemName: "gearshape").font(.system(size: 15)).frame(width: 44, height: 44)
        }
        .modifier(ClearGlassControl(radius: 22)).buttonStyle(GlassPressStyle())
        .help("Settings")
    }
    private var actionsMenu: some View {
        Menu {
            Button { importFiles(into: activeFolder) } label: { Label("Import Media", systemImage: "square.and.arrow.down") }
                .disabled(library.isImporting)
            Button { requestDelete(file: selectedFile, folder: selectedFile == nil ? activeFolder : nil) } label: { Label("Delete Selected Media", systemImage: "trash") }
                .disabled(selectedFile == nil && activeFolder == nil)
            Button { showDownloads.toggle() } label: { Label("Download from a link", systemImage: "arrow.down.circle") }
            Button { withAnimation(motion) { showSettings = true } } label: { Label("Settings", systemImage: "gearshape") }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 15, weight: .medium)).frame(width: 44, height: 44)
        }
        .modifier(ClearGlassControl(radius: 22))
        .buttonStyle(GlassPressStyle())
        .help("More Library Actions")
        .popover(isPresented: $showDownloads, arrowEdge: .top) {
            DownloadComposer(engine: engine, library: library) { showDownloads = false }.frame(width: 440)
        }
    }
    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text((destination ?? .all).title).font(.system(size: 30, weight: .bold, design: .default))
                Text(library.isImporting ? "Importing your media…" : "\(visibleFiles.count) \(visibleFiles.count == 1 ? "item" : "items")")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button { if let first = visibleFiles.first { playback.play(first, queue: visibleFiles) } } label: {
                Label("Play", systemImage: "play.fill").frame(minWidth: 64)
            }.buttonStyle(.borderedProminent).controlSize(.large).disabled(visibleFiles.isEmpty)
            Button { let shuffled = visibleFiles.shuffled(); if let first = shuffled.first { playback.play(first, queue: shuffled) } } label: {
                Image(systemName: "shuffle").frame(width: 24)
            }.buttonStyle(.bordered).controlSize(.large).disabled(visibleFiles.isEmpty).help("Shuffle")
        }.padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 22)
    }
    private var mediaList: some View {
        List(selection: $selection) {
            if destination == .all && query.isEmpty && !library.folders.isEmpty {
                ForEach(library.folders, id: \.self) { folder in
                    DisclosureGroup(isExpanded: expanded(folder)) {
                        ForEach(visibleFiles.filter { library.assignments[$0.id] == folder }) { file in mediaRow(file).tag(file.id) }
                    } label: {
                        HStack {
                            Label(folder, systemImage: "music.note.list").font(.headline)
                            Spacer()
                            Text("\(visibleFiles.filter { library.assignments[$0.id] == folder }.count)").foregroundStyle(.secondary).font(.caption)
                        }.padding(.vertical, 8)
                    }
                    .onDrop(of: [.fileURL, .plainText], isTargeted: nil) { drop($0, into: folder) }
                    .contextMenu {
                        Button("Play") { playFolder(folder) }
                        Button("Import Music…") { importFiles(into: folder) }
                        Button("Rename Folder…") { beginName(folder: folder) }
                        Button("Delete Folder…", role: .destructive) { requestDelete(folder: folder) }
                    }
                }
                ForEach(visibleFiles.filter { library.assignments[$0.id] == nil }) { file in mediaRow(file).tag(file.id) }
            } else {
                ForEach(visibleFiles) { file in mediaRow(file).tag(file.id) }
            }
        }
        .listStyle(.inset).scrollContentBackground(.hidden)
        .onDeleteCommand {
            guard isActive && !showPlayer && !naming && !deleting && !showSettings && !showDownloads else { return }
            if let selectedFile { requestDelete(file: selectedFile) }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { drop($0, into: activeFolder) }
    }
    private func mediaRow(_ file: MediaFile) -> some View {
        HStack(spacing: 14) {
            MediaArtwork(file: file, size: 46)
            VStack(alignment: .leading, spacing: 4) {
                Text(file.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(file.kind == "MP4" ? "Video · MP4" : "Audio · MP3").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if playback.currentFile?.id == file.id {
                Image(systemName: playback.isPlaying ? "waveform" : "pause.fill").foregroundStyle(accent).accessibilityLabel(playback.isPlaying ? "Playing" : "Paused")
            }
            Menu { fileMenu(file) } label: { Image(systemName: "ellipsis").frame(width: 24, height: 30) }.menuStyle(.borderlessButton).fixedSize().help("File actions")
        }
        .padding(.vertical, 7).contentShape(Rectangle())
        .onTapGesture(count: 2) { selection = file.id; playback.play(file, queue: visibleFiles) }
        .contextMenu { fileMenu(file) }
        .onDrag { NSItemProvider(object: file.id as NSString) }
    }
    @ViewBuilder private func fileMenu(_ file: MediaFile) -> some View {
        Button("Play") { playback.play(file, queue: visibleFiles) }
        Button("Show in Finder") { library.reveal(file) }
        Button("Open With Default App") { library.open(file) }
        Divider()
        Button("Choose Artwork…") { artworkOverrides.choose(file: file) }
        Button("Reset Artwork") { artworkOverrides.clear(file: file) }
            .disabled(!artworkOverrides.hasOverride(for: file))
        Divider()
        Button("Rename…") { beginName(file: file) }
        Button("Move File…") { move(file) }
        Menu("Add to Folder") {
            ForEach(library.folders, id: \.self) { folder in Button(folder) { library.assign(file, to: folder) } }
            if library.assignments[file.id] != nil { Button("Remove from Folder") { library.assign(file, to: nil) } }
        }
        Divider()
        Button("Move to Trash…", role: .destructive) { requestDelete(file: file) }
    }
    private var emptyLibrary: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: query.isEmpty ? "music.note.house" : "magnifyingglass").font(.system(size: 48, weight: .ultraLight)).foregroundStyle(.tertiary)
            Text(query.isEmpty ? "Your library starts here" : "No results").font(.title2.weight(.semibold))
            Text(query.isEmpty ? "Import music and videos, or save something from a link." : "Try another title.")
                .foregroundStyle(.secondary).font(.subheadline)
            if query.isEmpty {
                HStack(spacing: 12) {
                    Button("Import Media…") { importFiles(into: activeFolder) }
                    Button("Download from Link…") { showDownloads = true }
                }.buttonStyle(.bordered).padding(.top, 4)
            }
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
    }
    private var downloadStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: engine.isRunning ? "arrow.down.circle" : engine.status == "Download success" ? "checkmark.circle" : "info.circle").foregroundStyle(accent)
                Text(engine.status).font(.caption).lineLimit(2)
                Spacer()
                if engine.isRunning { Button("Cancel") { engine.cancel() }.controlSize(.small) }
            }
            if engine.isRunning { ProgressView(value: engine.progress).tint(accent) }
        }.padding(.horizontal, 28).padding(.bottom, 16)
    }
    @ViewBuilder private var settingsPanel: some View {
        if showSettings {
            ZStack(alignment: .trailing) {
                Color.black.opacity(0.35).contentShape(Rectangle()).onTapGesture { showSettings = false }
                SettingsView { showSettings = false }.padding(14).transition(.move(edge: .trailing).combined(with: .opacity))
            }.onExitCommand { showSettings = false }
        }
    }
    private var namingPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(renameFile != nil ? "Rename File" : renameFolder != nil ? "Rename Folder" : "New Folder").font(.title3.bold())
            TextField("Name", text: $newName).textFieldStyle(.roundedBorder).onSubmit(saveName)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { naming = false }
                Button("Save", action: saveName).keyboardShortcut(.defaultAction).disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(26).frame(width: 370)
    }
    private var deletionPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(deleteFolder == nil ? "Move to Trash?" : "Delete Folder?", systemImage: "trash").font(.title3.bold())
            Text(deleteFile?.name ?? deleteFolder ?? "").foregroundStyle(.secondary).lineLimit(3)
            if deleteFolder != nil { Toggle("Also move the media inside to Trash", isOn: $deleteContents) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { deleting = false }
                Button(deleteFolder != nil && !deleteContents ? "Delete Folder" : "Move to Trash", role: .destructive) {
                    if let deleteFile {
                        if playback.currentFile?.id == deleteFile.id { playback.stop() }
                        library.trash(deleteFile)
                    }
                    if let deleteFolder {
                        if deleteContents, let current = playback.currentFile, library.assignments[current.id] == deleteFolder { playback.stop() }
                        library.trashFolder(deleteFolder, includingFiles: deleteContents)
                        destination = .all
                    }
                    selection = nil; deleting = false
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 390)
    }
    private func expanded(_ folder: String) -> Binding<Bool> {
        Binding(get: { library.expanded.contains(folder) }, set: { value in withAnimation(motion) { if value { library.expanded.insert(folder) } else { library.expanded.remove(folder) } } })
    }
    private func playFolder(_ folder: String) {
        let files = library.files.filter { library.assignments[$0.id] == folder }
        if let first = files.first { playback.play(first, queue: files) }
    }
    private func beginName(file: MediaFile? = nil, folder: String? = nil) {
        renameFile = file; renameFolder = folder; newName = file?.name ?? folder ?? ""; naming = true
    }
    private func saveName() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let renameFile { library.rename(renameFile, to: name) }
        else if let renameFolder { library.renameFolder(renameFolder, to: name); destination = .folder(name) }
        else { library.createFolder(name); destination = .folder(name) }
        naming = false
    }
    private func requestDelete(file: MediaFile? = nil, folder: String? = nil) {
        guard file != nil || folder != nil else { return }
        deleteFile = file; deleteFolder = folder; deleteContents = false; deleting = true
    }
    private func importFiles(into folder: String?) {
        MediaImportPicker.shared.open { urls in library.importMediaAsync(urls: urls, folder: folder) }
    }
    private func move(_ file: MediaFile) {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.prompt = "Move Here"
        if panel.runModal() == .OK, let target = panel.url { library.move(file, to: target) }
    }
    private func drop(_ providers: [NSItemProvider], into folder: String?) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
                    let url = (value as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) } ?? value as? URL
                    if let url { DispatchQueue.main.async { library.importMediaAsync(urls: [url], folder: folder) } }
                }
            } else {
                _ = provider.loadObject(ofClass: String.self) { value, _ in
                    guard let value else { return }
                    DispatchQueue.main.async { if let file = library.files.first(where: { $0.id == value }) { library.assign(file, to: folder) } }
                }
            }
        }
        return !providers.isEmpty
    }
}

private struct DownloadComposer: View {
    @ObservedObject var engine: DownloadEngine
    @ObservedObject var library: LibraryStore
    let onStart: () -> Void
    @State private var link = ""
    @State private var format = "MP4"
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Save from a Link", systemImage: "arrow.down.circle").font(.title3.bold())
            HStack {
                TextField("Paste a video link", text: $link).textFieldStyle(.roundedBorder).onSubmit(start)
                Button("Paste") { link = NSPasteboard.general.string(forType: .string) ?? "" }
            }
            SegmentPill(values: ["MP4", "MP3", "Both"], selection: $format).frame(height: 40)
            Text("Your downloads appear in the library and are copied to Downloads.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Download", action: start).buttonStyle(.borderedProminent).disabled(engine.isRunning || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24)
    }
    private func start() {
        engine.start(url: link, format: format, destination: library.root) { library.refresh() }
        onStart()
    }
}
