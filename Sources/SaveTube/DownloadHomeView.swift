import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Persists the downloader's work when switching to the Player page.
@MainActor
final class DownloadHomeState: ObservableObject {
    @Published var link = ""
    @Published var format = "MP4"
    @Published var filter = "All"
    @Published var query = ""
    @Published var selected: String?
    @Published var notice = ""
}

/// The original centered downloader and compact file manager are the main page.
struct DownloadHomeView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var engine: DownloadEngine
    @ObservedObject var state: DownloadHomeState
    let playInPlayer: (MediaFile) -> Void
    @ObservedObject private var theme = ThemeStore.shared
    @AppStorage("SaveTube.backgroundOpacity") private var backgroundOpacity = 0.72
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settings = false
    @State private var naming = false
    @State private var name = ""
    @State private var oldFolder: String?
    @State private var namedFile: MediaFile?
    @State private var folderAssignment: MediaFile?
    @State private var deleting = false
    @State private var deletedFile: MediaFile?
    @State private var deletedFolder: String?
    @State private var deleteContents = false
    @FocusState private var searchFocused: Bool
    private var motion: Animation? { reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.86) }
    private var matches: [MediaFile] {
        library.files.filter {
            (state.filter == "All" || $0.kind == state.filter) &&
            (state.query.isEmpty || $0.name.localizedCaseInsensitiveContains(state.query))
        }
    }
    private var selectedFile: MediaFile? { library.files.first { $0.id == state.selected } }
    private var selectedFolder: String? {
        guard let value = state.selected, value.hasPrefix("folder:") else { return nil }
        let folder = String(value.dropFirst(7))
        return library.folders.contains(folder) ? folder : nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Savetube").font(.system(size: 24, weight: .bold)).padding(.bottom, 24)
            HStack(spacing: 12) {
                TextField("Paste a video link…", text: $state.link)
                    .textFieldStyle(.plain).font(.system(size: 13)).onSubmit(download)
                PillButton(title: "Paste", action: paste).frame(width: 88, height: 32)
            }
            .padding(.leading, 24).padding(.trailing, 8).frame(height: 48)
            .modifier(ClearGlassControl())
            .padding(.bottom, 16)
            HStack(spacing: 16) {
                SegmentPill(values: ["MP4", "MP3", "Both"], selection: $state.format).frame(maxWidth: 260).frame(height: 44)
                Spacer(minLength: 0)
                PillButton(title: "Open Folder", action: openFolder).frame(width: 140, height: 44)
                PillButton(title: "Download", solid: true, action: download).frame(width: 160, height: 44)
            }
            downloadStatus.padding(.top, 12).padding(.bottom, 24)
            HStack(spacing: 16) {
                Text("Library").font(.system(size: 14, weight: .bold))
                Text("\(matches.count) \(matches.count == 1 ? "item" : "items")").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                PillButton(title: "+  Folder") { beginName() }.frame(width: 112, height: 34)
                SegmentPill(values: ["All", "MP4", "MP3"], selection: $state.filter, small: true).frame(width: 180, height: 34)
            }.padding(.bottom, 12)
            HStack(spacing: 14) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search library…", text: $state.query).textFieldStyle(.plain).font(.system(size: 12)).focused($searchFocused)
                if !state.query.isEmpty {
                    Button { state.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 18).frame(height: 42).modifier(ClearGlassControl(focused: searchFocused)).padding(.bottom, 16)
            fileActions.padding(.bottom, 12)
            fileList.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let selectedFile {
                Text(selectedFile.url.deletingLastPathComponent().path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).padding(.top, 8)
            }
        }
        .frame(maxWidth: 880).padding(.horizontal, 40).padding(.top, 38).padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            if theme.glassBackground { WindowBackdrop(glass: true).overlay(Color.black.opacity(backgroundOpacity)) }
            else { Color.black }
        }
        .overlay { settingsPanel }
        .sheet(isPresented: $naming) { namingPanel }
        .sheet(isPresented: $deleting) { deletionPanel }
        .onReceive(NotificationCenter.default.publisher(for: .showSaveTubeSettings)) { _ in settings = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in library.refresh() }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in library.refresh() }
        .background {
            Button("") { searchFocused = true }.keyboardShortcut("f").hidden()
            Button("", action: paste).keyboardShortcut("v", modifiers: [.command, .shift]).hidden()
        }
        .background(LibraryKeyboard(onMove: { _ in false }, onOpen: {
            guard !naming && !deleting && !settings, let selectedFile else { return false }
            playInPlayer(selectedFile); return true
        }, onEscape: {
            guard searchFocused else { return false }; state.query = ""; searchFocused = false; return true
        }).frame(width: 0, height: 0))
        .alert("Library", isPresented: Binding(get: { library.lastError != nil }, set: { if !$0 { library.lastError = nil } })) {
            Button("OK") { library.lastError = nil }
        } message: { Text(library.lastError ?? "") }
        .animation(motion, value: settings)
        .animation(motion, value: library.expanded)
    }
    private var downloadStatus: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(engine.status.isEmpty ? state.notice : engine.status).lineLimit(1)
                Spacer()
                if engine.isRunning { Text("\(Int(engine.progress * 100))%") }
            }.font(.system(size: 10)).foregroundStyle(.secondary).frame(height: 14)
            Capsule().fill(Color.white.opacity(0.08)).frame(height: 3).overlay(alignment: .leading) {
                GeometryReader { geometry in Capsule().fill(theme.accent.opacity(0.8)).frame(width: geometry.size.width * min(1, max(0, engine.progress))) }
            }.opacity(engine.isRunning || engine.progress > 0 ? 1 : 0)
        }
    }
    private var fileActions: some View {
        HStack(spacing: 16) {
            PillButton(title: library.isImporting ? "Importing…" : "Import") { importMedia(into: selectedFolder) }.frame(width: library.isImporting ? 100 : 74).disabled(library.isImporting)
            PillButton(title: "Rename") {
                if let selectedFile { beginName(file: selectedFile) }
                else if let selectedFolder { beginName(folder: selectedFolder) }
            }.frame(width: 78).disabled((selectedFile == nil && selectedFolder == nil) || library.isImporting)
            PillButton(title: "Move") { if let selectedFile { move(selectedFile) } }.frame(width: 66).disabled(selectedFile == nil || library.isImporting)
            PillButton(title: "Delete") { requestDelete(file: selectedFile, folder: selectedFolder) }.frame(width: 74).disabled((selectedFile == nil && selectedFolder == nil) || library.isImporting)
            Spacer()
            Button { settings = true } label: {
                Image(systemName: "gearshape").frame(width: 38, height: 32).modifier(ClearGlassControl())
            }.buttonStyle(GlassPressStyle()).help("Settings")
        }.frame(height: 34)
    }
    private var fileList: some View {
        ZStack {
            if matches.isEmpty && library.folders.isEmpty {
                Text(state.query.isEmpty ? "Nothing here yet." : "No matches.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            List(selection: $state.selected) {
                ForEach(library.folders.filter { folder in state.query.isEmpty || matches.contains { library.assignments[$0.id] == folder } }, id: \.self) { folder in
                    DisclosureGroup(isExpanded: Binding(get: { library.expanded.contains(folder) || !state.query.isEmpty }, set: { value in
                        if value { library.expanded.insert(folder) } else { library.expanded.remove(folder) }
                    })) {
                        ForEach(matches.filter { library.assignments[$0.id] == folder }) { file in row(file).tag(file.id) }
                    } label: {
                        HStack {
                            Image(systemName: "folder").foregroundStyle(theme.accent.opacity(0.8))
                            Text(folder).font(.system(size: 13, weight: .bold))
                            Spacer()
                            Text("\(matches.filter { library.assignments[$0.id] == folder }.count)").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 8).contentShape(Rectangle())
                    }.tag("folder:" + folder)
                    .contextMenu {
                        Button("Import Music…") { importMedia(into: folder) }
                        Button("Rename Folder…") { beginName(folder: folder) }
                        Button("Delete Folder…", role: .destructive) { requestDelete(folder: folder) }
                    }
                    .onDrop(of: [.plainText, .fileURL], isTargeted: nil) { drop($0, into: folder) }
                }
                ForEach(matches.filter { library.assignments[$0.id] == nil }) { file in row(file).tag(file.id) }
            }.listStyle(.plain).scrollContentBackground(.hidden)
                .onDeleteCommand { requestDelete(file: selectedFile, folder: selectedFolder) }
                .onDrop(of: [.fileURL], isTargeted: nil) { drop($0, into: selectedFolder) }
        }
    }
    private func row(_ file: MediaFile) -> some View {
        HStack(spacing: 16) {
            Circle().fill(Color.white.opacity(file.kind == "MP3" ? 0.8 : 0.4)).frame(width: 7, height: 7)
            Text(file.name).font(.system(size: 13)).lineLimit(1)
            Spacer()
            Text(file.kind).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
        }.padding(.vertical, 10).contentShape(Rectangle())
            .onTapGesture(count: 2) { playInPlayer(file) }
            .onDrag { NSItemProvider(object: file.id as NSString) }
            .contextMenu {
                Button("Play in Player") { playInPlayer(file) }
                Button("Show in Finder") { library.reveal(file) }
                Button("Open With Default App") { library.open(file) }
                Divider()
                Button("Rename…") { beginName(file: file) }
                Button("Move File…") { move(file) }
                Menu("Move to Folder") {
                    ForEach(library.folders, id: \.self) { folder in Button(folder) { library.assign(file, to: folder) } }
                    Button("New Folder…") { beginName(assigning: file) }
                    if library.assignments[file.id] != nil { Button("Remove from Folder") { library.assign(file, to: nil) } }
                }
                Button("Delete File…", role: .destructive) { requestDelete(file: file) }
            }
    }
    @ViewBuilder private var settingsPanel: some View {
        if settings {
            ZStack(alignment: .trailing) {
                Color.black.opacity(0.4).onTapGesture { settings = false }
                SettingsView { settings = false }.padding(14).transition(.move(edge: .trailing).combined(with: .opacity))
            }.onExitCommand { settings = false }
        }
    }
    private var namingPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(namedFile != nil ? "Rename File" : oldFolder == nil ? "New Folder" : "Rename Folder").font(.headline)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).onSubmit(saveName)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { naming = false }
                Button("Save", action: saveName).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(26).frame(width: 370)
    }
    private var deletionPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(deletedFolder != nil ? "Delete Folder?" : "Move File to Trash?").font(.headline)
            Text(deletedFile?.name ?? deletedFolder ?? "").foregroundStyle(.secondary)
            if deletedFolder != nil { Toggle("Also move the media inside to Trash", isOn: $deleteContents) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { deleting = false }
                Button(deletedFolder != nil && !deleteContents ? "Delete Folder" : "Move to Trash", role: .destructive) {
                    if let deletedFile {
                        if PlaybackStore.shared.currentFile?.id == deletedFile.id { PlaybackStore.shared.stop() }
                        library.trash(deletedFile)
                    }
                    if let deletedFolder {
                        if deleteContents, let current = PlaybackStore.shared.currentFile, library.assignments[current.id] == deletedFolder { PlaybackStore.shared.stop() }
                        library.trashFolder(deletedFolder, includingFiles: deleteContents)
                    }
                    state.selected = nil; deleting = false
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 390)
    }
    private func download() { engine.start(url: state.link, format: state.format, destination: library.root) { library.refresh() } }
    private func paste() {
        if let value = NSPasteboard.general.string(forType: .string), !value.isEmpty { state.link = value.trimmingCharacters(in: .whitespacesAndNewlines); state.notice = "Link pasted." }
        else { state.notice = "Clipboard is empty." }
    }
    private func openFolder() {
        NSWorkspace.shared.open(state.format == "Both" ? library.root : library.root.appendingPathComponent(state.format))
    }
    private func beginName(file: MediaFile? = nil, folder: String? = nil, assigning: MediaFile? = nil) {
        namedFile = file; oldFolder = folder; folderAssignment = assigning; name = file?.name ?? folder ?? ""; naming = true
    }
    private func saveName() {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if let namedFile { library.rename(namedFile, to: value) }
        else if let oldFolder { library.renameFolder(oldFolder, to: value) }
        else { library.createFolder(value); if let folderAssignment { library.assign(folderAssignment, to: value) } }
        naming = false
    }
    private func requestDelete(file: MediaFile? = nil, folder: String? = nil) {
        guard file != nil || folder != nil else { return }
        deletedFile = file; deletedFolder = folder; deleteContents = false; deleting = true
    }
    private func importMedia(into folder: String?) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.mp3, .mpeg4Movie]; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { library.importMediaAsync(urls: panel.urls, folder: folder) }
    }
    private func move(_ file: MediaFile) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Move Here"
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
                    guard let value else { return }; DispatchQueue.main.async { if let file = library.files.first(where: { $0.id == value }) { library.assign(file, to: folder) } }
                }
            }
        }
        return !providers.isEmpty
    }
}
