import AppKit
import Darwin
import Foundation

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure(description: message) }
}

func waitFor(_ message: String, timeout: TimeInterval = 8, condition: () throws -> Bool) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try condition() { return }
        Thread.sleep(forTimeInterval: 0.05)
    }
    throw CheckFailure(description: "Timed out: \(message)")
}

func waitForMain(_ message: String, timeout: TimeInterval = 8, condition: () throws -> Bool) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try condition() { return }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    throw CheckFailure(description: "Timed out: \(message)")
}

@MainActor
func checkLibrary(in base: URL) throws {
    let manager = FileManager.default
    let root = base.appendingPathComponent("library")
    let store = LibraryStore(root: root)
    let audio = root.appendingPathComponent("MP3/Example.MP3")
    let video = root.appendingPathComponent("MP4/Video.mp4")
    try Data("audio".utf8).write(to: audio)
    try Data("video".utf8).write(to: video)
    try Data("partial".utf8).write(to: root.appendingPathComponent("MP3/Incomplete.mp3.part"))
    store.refresh()
    try check(store.files.count == 2, "Scan must include finished media and exclude partials")
    let file = try store.files.first.unwrap("Missing scanned media")
    store.createFolder("  Watch later  ")
    store.createFolder("Watch later")
    try check(store.folders == ["Watch later"], "Folder names must trim and reject duplicates")
    // Drag/drop resolves the row's stable ID, then calls the same assignment API.
    let draggedID = file.id
    let droppedFile = try store.files.first(where: { $0.id == draggedID }).unwrap("Drop lost file ID")
    store.assign(droppedFile, to: "Watch later")
    try check(store.assignments[file.id] == "Watch later", "Drop assignment did not persist")
    store.renameFolder("Watch later", to: "Favorites")
    let restored = LibraryStore(root: root)
    try check(restored.folders == ["Favorites"], "Folder rename did not reload")
    try check(restored.assignments[file.id] == "Favorites", "Rename lost file assignment")
    restored.deleteFolder("Favorites")
    try check(restored.files.count == 2 && restored.assignments.isEmpty, "Deleting virtual folder removed files")
    try check(manager.fileExists(atPath: audio.path) && manager.fileExists(atPath: video.path), "Media must remain after deleting virtual folder")
    restored.createFolder("Saved")
    restored.assign(file, to: "Saved")
    try manager.removeItem(at: file.url)
    restored.refresh()
    try check(restored.files.count == 1 && restored.assignments[file.id] == "Saved", "Missing tracked media must retain its virtual folder assignment")

    let corruptRoot = base.appendingPathComponent("corrupt-library")
    try manager.createDirectory(at: corruptRoot, withIntermediateDirectories: true)
    let corruptData = Data("preserve unreadable metadata".utf8)
    let metadata = corruptRoot.appendingPathComponent(".library.json")
    try corruptData.write(to: metadata)
    let corruptStore = LibraryStore(root: corruptRoot)
    corruptStore.createFolder("Must not overwrite")
    try check(corruptStore.lastError != nil, "Corrupt metadata must report an error")
    try check(try Data(contentsOf: metadata) == corruptData, "Corrupt metadata was overwritten")
    print("PASS library: scan, partial filtering, virtual folders, drag ID assignment, rename, reload, safe deletion, missing-file assignment retention, corrupt metadata preservation")
}

@MainActor
func checkFileManagement(in base: URL) throws {
    let manager = FileManager.default
    let root = base.appendingPathComponent("file-manager")
    let outside = base.appendingPathComponent("outside-library")
    let simulatedTrash = base.appendingPathComponent("isolated-test-trash")
    try manager.createDirectory(at: outside, withIntermediateDirectories: true)
    try manager.createDirectory(at: simulatedTrash, withIntermediateDirectories: true)
    var trashedPaths: [String] = []
    let trash: (URL) throws -> Void = { url in
        trashedPaths.append(url.path)
        try manager.moveItem(at: url, to: simulatedTrash.appendingPathComponent(UUID().uuidString))
    }
    let store = LibraryStore(root: root, trashHandler: trash)
    let original = root.appendingPathComponent("MP3/Tracked.mp3")
    try Data("tracked audio".utf8).write(to: original)
    store.refresh()
    let file = try store.files.first.unwrap("Missing tracking fixture")
    let stableID = file.id
    store.createFolder("Music")
    store.assign(file, to: "Music")
    store.rename(file, to: "Renamed")
    let renamed = try store.files.first.unwrap("Renamed media vanished")
    try check(renamed.id == stableID && renamed.url.lastPathComponent == "Renamed.mp3", "Rename did not retain the stable row ID")
    store.move(file, to: outside)
    let moved = try store.files.first.unwrap("Moved media vanished")
    try check(moved.id == stableID && moved.url.deletingLastPathComponent().standardizedFileURL.path == outside.standardizedFileURL.path, "Move did not retain an outside-library row")
    let finderMoved = outside.appendingPathComponent("Finder moved.mp3")
    try manager.moveItem(at: moved.url, to: finderMoved)
    store.refresh()
    let found = try store.files.first.unwrap("Bookmark did not follow a Finder-style move")
    try check(found.id == stableID && found.url.lastPathComponent == "Finder moved.mp3", "Finder move lost stable ID or current path")
    let restored = LibraryStore(root: root, trashHandler: trash)
    try check(restored.files.first?.id == stableID, "Bookmark location did not survive reload")
    try check(restored.assignments[stableID] == "Music", "File move lost its virtual folder")
    // Reusing the former path must never redirect deletion to unrelated content.
    try Data("unrelated replacement".utf8).write(to: original)
    restored.refresh()
    try check(restored.files.count == 2, "Replacement at original path overwrote the tracked row")
    let expectedTrashPointer = try realpath(finderMoved.path, nil).unwrap("Could not canonicalize the moved fixture")
    defer { free(expectedTrashPointer) }
    let expectedTrashPath = String(cString: expectedTrashPointer)
    restored.trash(file) // Deliberately pass the stale pre-rename row snapshot.
    try check(trashedPaths.last.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == expectedTrashPath, "Trash path mismatch: \(trashedPaths.last ?? "nil") expected \(expectedTrashPath)")
    try check(manager.fileExists(atPath: original.path), "Trash deleted unrelated replacement media")
    try check(!manager.fileExists(atPath: finderMoved.path), "Tracked moved file was not deleted at its current path")
    let afterTrash = LibraryStore(root: root, trashHandler: trash)
    try check(!afterTrash.files.contains(where: { $0.id == stableID }), "Trashed record reappeared after reload")

    let importSource = base.appendingPathComponent("import-source")
    try manager.createDirectory(at: importSource, withIntermediateDirectories: true)
    let imported = importSource.appendingPathComponent("Imported.mp3")
    try Data("import music".utf8).write(to: imported)
    afterTrash.importMedia(urls: [imported], folder: "Imported music")
    let importedFile = try afterTrash.files.first(where: { $0.name == "Imported" }).unwrap("Music import is missing")
    try check(afterTrash.assignments[importedFile.id] == "Imported music", "Music import did not join the chosen virtual folder")
    try check(manager.fileExists(atPath: imported.path), "Music import changed the source file")
    afterTrash.trashFolder("Imported music", includingFiles: true)
    try check(!afterTrash.folders.contains("Imported music"), "Trashed folder remained after all members succeeded")
    try check(!afterTrash.files.contains(where: { $0.id == importedFile.id }), "Trashing folder contents kept imported media")
    print("PASS file manager: stable IDs, rename, outside move, Finder move bookmarks, persisted paths, safe deletion at current path, music import and folder contents deletion")
}

@MainActor
func checkAsyncImport(in base: URL) throws {
    let manager = FileManager.default
    let root = base.appendingPathComponent("async-import-library")
    let source = base.appendingPathComponent("async-import-source")
    try manager.createDirectory(at: source, withIntermediateDirectories: true)
    let first = source.appendingPathComponent("First.mp3")
    let second = source.appendingPathComponent("Second.mp4")
    let unsupported = source.appendingPathComponent("Unsupported.txt")
    try Data(repeating: 0x31, count: 2 * 1024 * 1024).write(to: first)
    try Data(repeating: 0x32, count: 2 * 1024 * 1024).write(to: second)
    try Data("unsupported".utf8).write(to: unsupported)
    let store = LibraryStore(root: root)
    store.importMediaAsync(urls: [first], folder: "Queued imports")
    store.importMediaAsync(urls: [second, unsupported], folder: "Queued imports")
    try check(store.isImporting, "Async imports did not publish their busy state immediately")
    try check(store.files.isEmpty, "Async import performed a synchronous main-thread merge")
    let deadline = Date().addingTimeInterval(12)
    while store.isImporting && Date() < deadline {
        // Pump the main queue so background completion can merge on MainActor.
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    try check(!store.isImporting, "Async import never cleared its busy state")
    try check(store.files.count == 2, "Queued imports did not merge both valid media files")
    try check(store.files.allSatisfy { store.assignments[$0.id] == "Queued imports" }, "Async import did not assign the chosen folder")
    try check(store.lastError?.contains("Unsupported.txt") == true, "Async import did not surface worker errors")
    try check(manager.fileExists(atPath: first.path) && manager.fileExists(atPath: second.path), "Async import changed original files")
    let restored = LibraryStore(root: root)
    try check(restored.files.count == 2 && restored.assignments.count == 2, "Async import did not persist registrations and assignments")
    let changing = LibraryStore(root: base.appendingPathComponent("async-changing-folders"))
    changing.importMediaAsync(urls: [first], folder: "Rename me")
    changing.renameFolder("Rename me", to: "Renamed during import")
    changing.importMediaAsync(urls: [second], folder: "Delete me")
    changing.deleteFolder("Delete me")
    let changeDeadline = Date().addingTimeInterval(12)
    while changing.isImporting && Date() < changeDeadline {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    try check(!changing.isImporting && changing.files.count == 2, "Folder changes interrupted valid imports")
    let renamedImport = try changing.files.first(where: { $0.kind == "MP3" }).unwrap("Renamed-folder import missing")
    let unfiledImport = try changing.files.first(where: { $0.kind == "MP4" }).unwrap("Deleted-folder import missing")
    try check(changing.assignments[renamedImport.id] == "Renamed during import", "Pending import did not follow a folder rename")
    try check(changing.assignments[unfiledImport.id] == nil && !changing.folders.contains("Delete me"), "Pending import resurrected a deleted folder")
    print("PASS async imports: queued copies, errors, persistence, destination rename and deletion during copy")
}

@MainActor
func checkMigration(in base: URL) throws {
    let manager = FileManager.default
    let legacy = base.appendingPathComponent("original-history")
    let root = base.appendingPathComponent("imported-history")
    for directory in [".Dmp3", ".Dmp4"] {
        try manager.createDirectory(at: legacy.appendingPathComponent(directory), withIntermediateDirectories: true)
    }
    let oldAudio = legacy.appendingPathComponent(".Dmp3/Example.mp3")
    let oldVideo = legacy.appendingPathComponent(".Dmp4/Example.mp4")
    let audioData = Data("original audio history".utf8)
    let videoData = Data("original video history".utf8)
    try audioData.write(to: oldAudio)
    try videoData.write(to: oldVideo)
    try Data("do not import helper source".utf8).write(to: legacy.appendingPathComponent(".Dmp3/Mp3DupliDestination.py"))
    let metadata = Data(#"{"folders":["Old favorites"],"assign":{"[MP3] Example.mp3":"Old favorites","[MP4] Example.mp4":"Old favorites"}}"#.utf8)
    let metadataURL = legacy.appendingPathComponent(".library.json")
    try metadata.write(to: metadataURL)
    let store = LibraryStore(root: root)
    let existing = root.appendingPathComponent("MP3/Example.mp3")
    let existingData = Data("unrelated native media".utf8)
    try existingData.write(to: existing)
    store.refresh()
    store.createFolder("Existing group")
    let existingFile = try store.files.first.unwrap("Missing native fixture")
    store.assign(existingFile, to: "Existing group")
    store.importLegacy(from: legacy)
    try check(store.lastError == nil, "Valid legacy import reported an error")
    try check(store.files.count == 3, "Legacy import lost or duplicated media")
    try check(try Data(contentsOf: existing) == existingData, "Import overwrote native media")
    let importedAudio = root.appendingPathComponent("MP3/Example (1).mp3")
    try check(try Data(contentsOf: importedAudio) == audioData, "Collision did not create the expected separate copy")
    try check(store.assignments["[MP3] Example (1).mp3"] == "Old favorites", "Renamed import lost virtual folder assignment")
    try check(store.assignments[existingFile.id] == "Existing group", "Import changed an existing native classification")
    try check(store.folders.contains("Old favorites") && store.folders.contains("Existing group"), "Virtual folders did not merge")
    try check(try Data(contentsOf: oldAudio) == audioData, "Import altered original audio")
    try check(try Data(contentsOf: oldVideo) == videoData, "Import altered original video")
    try check(try Data(contentsOf: metadataURL) == metadata, "Import altered original metadata")
    store.importLegacy(from: legacy.appendingPathComponent(".Dmp3"))
    try check(store.files.count == 3, "Repeated import did not deduplicate identical content")
    let restored = LibraryStore(root: root)
    try check(restored.assignments["[MP3] Example (1).mp3"] == "Old favorites", "Imported metadata did not persist")

    let modern = base.appendingPathComponent("modern-history")
    try manager.createDirectory(at: modern.appendingPathComponent("MP3"), withIntermediateDirectories: true)
    try Data("modern history audio".utf8).write(to: modern.appendingPathComponent("MP3/Modern.mp3"))
    restored.importLegacy(from: modern)
    try check(restored.files.count == 4 && manager.fileExists(atPath: modern.appendingPathComponent("MP3/Modern.mp3").path), "Modern history was not copied safely")
    // A prior tracked row may retain the original filename ID after moving out.
    // New imported content at that filename must receive its own assignment.
    let collisionRoot = base.appendingPathComponent("moved-import-collision")
    let movedDirectory = base.appendingPathComponent("moved-import-media")
    try manager.createDirectory(at: movedDirectory, withIntermediateDirectories: true)
    let collisionStore = LibraryStore(root: collisionRoot)
    try existingData.write(to: collisionRoot.appendingPathComponent("MP3/Example.mp3"))
    collisionStore.refresh()
    let priorFile = try collisionStore.files.first.unwrap("Missing moved collision fixture")
    collisionStore.createFolder("Previous group")
    collisionStore.assign(priorFile, to: "Previous group")
    collisionStore.move(priorFile, to: movedDirectory)
    collisionStore.importLegacy(from: legacy)
    let newImported = try collisionStore.files.first(where: { $0.kind == "MP3" && $0.id != priorFile.id }).unwrap("Reused filename import is missing")
    try check(collisionStore.assignments[priorFile.id] == "Previous group", "Legacy import reassigned an older moved file")
    try check(collisionStore.assignments[newImported.id] == "Old favorites", "Reused filename import did not map to its new stable ID")
    print("PASS migration: legacy hidden directories, modern history, unchanged originals, collision-safe copies, deduplication, assignment remapping, merged folders and persistence")
}

@MainActor
func checkHelpers(in base: URL, downloads: URL) throws {
    let manager = FileManager.default
    let root = base.appendingPathComponent("helper-media")
    try manager.createDirectory(at: root.appendingPathComponent("MP3"), withIntermediateDirectories: true)
    try manager.createDirectory(at: root.appendingPathComponent("MP4"), withIntermediateDirectories: true)
    try manager.createDirectory(at: downloads, withIntermediateDirectories: true)
    let audio = root.appendingPathComponent("MP3/Example.mp3")
    let video = root.appendingPathComponent("MP4/Example.mp4")
    let partial = root.appendingPathComponent("MP3/Incomplete.mp3.part")
    let existing = downloads.appendingPathComponent("Example.mp3")
    let copiedAudio = downloads.appendingPathComponent("Example (1).mp3")
    let copiedVideo = downloads.appendingPathComponent("Example.mp4")
    try Data("existing unrelated audio".utf8).write(to: existing)
    try Data("downloaded audio".utf8).write(to: audio)
    try Data("downloaded video".utf8).write(to: video)
    try Data("incomplete".utf8).write(to: partial)
    let supervisor = HelperSupervisor()
    defer { supervisor.stop() }
    supervisor.start(root: root)
    let pidURLs = ["MP3", "MP4"].map { root.appendingPathComponent(".\($0)-test-helper.pid") }
    try waitFor("both helper processes launch") { pidURLs.allSatisfy { manager.fileExists(atPath: $0.path) } }
    let pids = try pidURLs.map { url -> Int32 in
        let value = try String(contentsOf: url, encoding: .utf8)
        guard let pid = Int32(value) else { throw CheckFailure(description: "Invalid helper PID") }
        return pid
    }
    try check(Set(pids).count == 2, "Formats must use separate helper processes")
    try waitFor("MP3 and MP4 completed copies") {
        manager.fileExists(atPath: copiedAudio.path) && manager.fileExists(atPath: copiedVideo.path)
    }
    try check(try Data(contentsOf: existing) == Data("existing unrelated audio".utf8), "Existing Downloads file was overwritten")
    try check(try Data(contentsOf: copiedAudio) == Data("downloaded audio".utf8), "Copied MP3 content differs")
    try check(try Data(contentsOf: copiedVideo) == Data("downloaded video".utf8), "Copied MP4 content differs")
    try check(!manager.fileExists(atPath: downloads.appendingPathComponent(partial.lastPathComponent).path), "Partial media was copied")
    try waitFor("both persistent deduplication records") {
        ["mp3", "mp4"].allSatisfy { manager.fileExists(atPath: root.appendingPathComponent(".\($0)-copies.json").path) }
    }
    supervisor.stop()
    try waitFor("both helpers terminate on stop") { pids.allSatisfy { kill($0, 0) == -1 && errno == ESRCH } }
    // Removing the completed destination deliberately verifies persisted fingerprints:
    // a helper restart must not repeatedly export the same source file.
    try manager.removeItem(at: copiedAudio)
    for url in pidURLs { try manager.removeItem(at: url) }
    supervisor.start(root: root)
    try waitFor("both helpers restart") { pidURLs.allSatisfy { manager.fileExists(atPath: $0.path) } }
    Thread.sleep(forTimeInterval: 2.5)
    try check(!manager.fileExists(atPath: copiedAudio.path), "Restart ignored persistent copy fingerprints")
    try check(!manager.fileExists(atPath: downloads.appendingPathComponent("Example (2).mp3").path), "Restart created a duplicate copy")
    let restartedPIDs = try pidURLs.map { Int32(try String(contentsOf: $0, encoding: .utf8))! }
    supervisor.stop()
    try waitFor("restarted helpers terminate") { restartedPIDs.allSatisfy { kill($0, 0) == -1 && errno == ESRCH } }

    let stream = HelperDiagnosticStream()
    try check(stream.consume(Data(repeating: 65, count: 100_000)).isEmpty, "Diagnostic stream emitted an incomplete line")
    let capped = stream.consume(Data("\n".utf8))
    try check(capped.count == 1 && capped[0].utf8.count <= 1_028 && capped[0].hasSuffix("…"), "Diagnostic stream retained an unbounded line")

    let failingRoot = base.appendingPathComponent("helper-failure")
    try manager.createDirectory(at: failingRoot.appendingPathComponent("MP3"), withIntermediateDirectories: true)
    try manager.createDirectory(at: failingRoot.appendingPathComponent("MP4"), withIntermediateDirectories: true)
    try manager.createDirectory(at: failingRoot.appendingPathComponent(".mp3-copies.json"), withIntermediateDirectories: true)
    try Data("copy with unwritable record".utf8).write(to: failingRoot.appendingPathComponent("MP3/Failure.mp3"))
    var failures: [String] = []
    let failingSupervisor = HelperSupervisor { failures.append($0) }
    failingSupervisor.start(root: failingRoot)
    try waitForMain("copy failure reaches the app") { failures.contains(where: { $0.contains("MP3 copy failed for Failure.mp3") }) }
    RunLoop.current.run(until: Date().addingTimeInterval(2.3))
    try check(failures.filter { $0.contains("MP3 copy failed") }.count == 1, "Persistent copy failure flooded the app with alerts")
    failingSupervisor.stop()
    let failureCount = failures.count
    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    try check(failures.count == failureCount, "Stopped helpers delivered late alerts")

    for url in pidURLs { try manager.removeItem(at: url) }
    var exitFailures: [String] = []
    let exitSupervisor = HelperSupervisor { exitFailures.append($0) }
    exitSupervisor.start(root: root)
    try waitFor("helpers for unexpected-exit check") { pidURLs.allSatisfy { manager.fileExists(atPath: $0.path) } }
    let exitPIDs = try pidURLs.map { Int32(try String(contentsOf: $0, encoding: .utf8))! }
    kill(exitPIDs[1], SIGKILL)
    try waitForMain("unexpected helper exit reaches the app") { exitFailures.contains(where: { $0.contains("MP4 copy helper stopped unexpectedly") }) }
    exitSupervisor.stop()
    try waitFor("unexpected-exit check cleans up remaining helper") { exitPIDs.allSatisfy { kill($0, 0) == -1 && errno == ESRCH } }
    print("PASS helpers: separate processes, stable copies, persistent deduplication, bounded diagnostics, deduped failure alerts, unexpected exit and stop cleanup")
}

extension Optional {
    func unwrap(_ message: String) throws -> Wrapped {
        guard let value = self else { throw CheckFailure(description: message) }
        return value
    }
}

if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--copy-helper", CommandLine.arguments[3] == "--media-root" {
    let kind = CommandLine.arguments[2]
    let root = URL(fileURLWithPath: CommandLine.arguments[4], isDirectory: true)
    try Data(String(getpid()).utf8).write(to: root.appendingPathComponent(".\(kind)-test-helper.pid"), options: .atomic)
    BackgroundCopier.run(kind: kind, root: root)
} else {
    do {
        let environment = ProcessInfo.processInfo.environment
        let base = URL(fileURLWithPath: try environment["SAVETUBE_TEST_ROOT"].unwrap("Run scripts/test-core.sh to isolate all test files"), isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let downloads = URL(fileURLWithPath: try environment["SAVETUBE_DOWNLOADS_DIR"].unwrap("An isolated Downloads directory is required"), isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        try check(downloads.path.hasPrefix(base.path + "/"), "Downloads override must be inside the isolated test root")
        try MainActor.assumeIsolated {
            try checkLibrary(in: base)
            try checkMigration(in: base)
            try checkFileManagement(in: base)
            try checkAsyncImport(in: base)
            try checkHelpers(in: base, downloads: downloads)
        }
    } catch {
        FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
        exit(1)
    }
}
