import AVFoundation
import Combine
import Foundation
import MediaPlayer

/// Owns the in-app player and the playback queue. All UI-facing state lives on the main actor.
@MainActor
final class PlaybackStore: ObservableObject {
    static let shared = PlaybackStore()

    @Published private(set) var currentFile: MediaFile?
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: Double = 0
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var error: String?
    @Published var volume: Double = 0.8 {
        didSet { player.volume = Float(min(max(volume, 0), 1)) }
    }

    let player = AVPlayer()
    private var queue: [MediaFile] = []
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var durationObservation: NSKeyValueObservation?
    private var playbackObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var remoteTargets: [(MPRemoteCommand, Any)] = []

    private init() {
        player.volume = Float(volume)
        playbackObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                self?.isPlaying = player.timeControlStatus == .playing
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let seconds = time.seconds
                self.currentTime = seconds.isFinite ? max(0, seconds) : 0
                self.updateDuration()
                self.updateNowPlaying()
            }
        }
        configureRemoteCommands()
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        statusObservation?.invalidate()
        durationObservation?.invalidate()
        playbackObservation?.invalidate()
        for (command, target) in remoteTargets { command.removeTarget(target) }
    }

    func play(_ file: MediaFile, queue newQueue: [MediaFile]) {
        guard FileManager.default.isReadableFile(atPath: file.url.path) else {
            error = "Could not play \(file.url.lastPathComponent): the file is unavailable."
            return
        }
        queue = newQueue.contains(file) ? newQueue : [file] + newQueue
        start(file)
    }

    func toggle() {
        guard currentFile != nil else { return }
        if isPlaying { pause() } else { player.play(); isPlaying = true }
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func stop() {
        player.pause()
        clearItemObservers()
        player.replaceCurrentItem(with: nil)
        queue = []
        currentFile = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        error = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite, player.currentItem != nil else { return }
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = target
    }

    func next() {
        guard let currentFile, let index = queue.firstIndex(of: currentFile) else { return }
        for file in queue.dropFirst(index + 1) where FileManager.default.isReadableFile(atPath: file.url.path) {
            start(file)
            return
        }
        error = "No more available files in the queue."
    }

    func previous() {
        if currentTime > 3 { seek(to: 0); return }
        guard let currentFile, let index = queue.firstIndex(of: currentFile), index > 0 else {
            seek(to: 0)
            return
        }
        for file in queue[..<index].reversed() where FileManager.default.isReadableFile(atPath: file.url.path) {
            start(file)
            return
        }
        seek(to: 0)
    }

    var canGoNext: Bool {
        guard let currentFile, let index = queue.firstIndex(of: currentFile) else { return false }
        return queue.dropFirst(index + 1).contains { FileManager.default.isReadableFile(atPath: $0.url.path) }
    }

    var canGoPrevious: Bool {
        guard let currentFile, let index = queue.firstIndex(of: currentFile) else { return false }
        return currentTime > 0 || queue[..<index].contains { FileManager.default.isReadableFile(atPath: $0.url.path) }
    }

    private func start(_ file: MediaFile) {
        guard FileManager.default.isReadableFile(atPath: file.url.path) else {
            error = "Could not play \(file.url.lastPathComponent): the file is unavailable."
            return
        }
        clearItemObservers()
        let item = AVPlayerItem(url: file.url)
        currentFile = file
        currentTime = 0
        duration = 0
        error = nil
        player.replaceCurrentItem(with: item)
        player.play()
        isPlaying = true
        updateNowPlaying()

        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item else { return }
                if item.status == .failed {
                    self.error = item.error?.localizedDescription ?? "This file could not be played."
                    self.pause()
                    self.updateNowPlaying()
                }
            }
        }
        durationObservation = item.observe(\.duration, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item else { return }
                self.updateDuration()
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item else { return }
                if self.canGoNext { self.next() } else { self.pause(); self.seek(to: 0) }
            }
        }
    }

    private func updateDuration() {
        guard let seconds = player.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 else { return }
        duration = seconds
    }

    private func clearItemObservers() {
        statusObservation?.invalidate()
        statusObservation = nil
        durationObservation?.invalidate()
        durationObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }

    private func updateNowPlaying() {
        guard let currentFile else { return }
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: currentFile.name,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        remoteTargets.append((center.playCommand, center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.currentFile != nil else { return }
                self.player.play()
                self.isPlaying = true
                self.updateNowPlaying()
            }
            return .success
        }))
        remoteTargets.append((center.pauseCommand, center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.pause(); self?.updateNowPlaying() }
            return .success
        }))
        remoteTargets.append((center.nextTrackCommand, center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.next() }
            return .success
        }))
        remoteTargets.append((center.previousTrackCommand, center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.previous() }
            return .success
        }))
        remoteTargets.append((center.changePlaybackPositionCommand, center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor [weak self] in self?.seek(to: event.positionTime) }
            return .success
        }))
    }
}
