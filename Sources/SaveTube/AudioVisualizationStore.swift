import Accelerate
import AVFoundation
import Combine
import Foundation

/// Analyses a local file independently of AVPlayer so visualisation never changes playback.
@MainActor
final class AudioVisualizationStore: ObservableObject {
    static let shared = AudioVisualizationStore()

    @Published private(set) var loading = false
    @Published private(set) var error: String?

    private static let emptyBands = [Float](repeating: 0, count: 24)
    private var activeKey: FileKey?
    private var activeAnalysis: AudioAnalysis?
    private var analysisTask: Task<Void, Never>?
    private var generation = UUID()
    private var cache: [FileKey: AudioAnalysis] = [:]
    private var cacheOrder: [FileKey] = []
    private var cacheBytes = 0
    private let cacheByteLimit = 32 * 1024 * 1024

    private init() {}

    func prepare(file: MediaFile) {
        do {
            let key = try FileKey(url: file.url)
            // Repeated SwiftUI lifecycle callbacks for the same file must not restart analysis.
            if activeKey == key, (activeAnalysis != nil || (analysisTask != nil && loading)) { return }
            analysisTask?.cancel()
            analysisTask = nil
            activeAnalysis = nil
            error = nil
            let nextGeneration = UUID()
            generation = nextGeneration
            activeKey = key
            if let cached = cache[key] {
                touch(key)
                activeAnalysis = cached
                loading = false
                return
            }
            loading = true
            analysisTask = Task.detached(priority: .utility) { [weak self] in
                do {
                    let analysis = try await AudioAnalysis.read(url: key.url) { [weak self] partial in
                        await self?.publish(partial, key: key, generation: nextGeneration)
                    }
                    await self?.finish(analysis: analysis, key: key, generation: nextGeneration)
                } catch is CancellationError {
                    // A newer file has taken over.
                } catch {
                    await self?.fail(error, generation: nextGeneration)
                }
            }
        } catch {
            analysisTask?.cancel()
            analysisTask = nil
            activeAnalysis = nil
            activeKey = nil
            loading = false
            self.error = error.localizedDescription
        }
    }

    /// Amplitudes from the decoded file at the player's current time, in low-to-high frequency order.
    func bands(at time: Double) -> [Float] {
        guard time.isFinite, let analysis = activeAnalysis else { return Self.emptyBands }
        return analysis.bands(at: max(0, time))
    }

    private func publish(_ analysis: AudioAnalysis, key: FileKey, generation: UUID) {
        guard self.generation == generation, activeKey == key else { return }
        activeAnalysis = analysis
    }

    private func finish(analysis: AudioAnalysis, key: FileKey, generation: UUID) {
        guard self.generation == generation, activeKey == key else { return }
        activeAnalysis = analysis
        loading = false
        analysisTask = nil
        cache[key] = analysis
        cacheBytes += analysis.byteCost
        touch(key)
        while cacheBytes > cacheByteLimit || cacheOrder.count > 4, let oldest = cacheOrder.first {
            cacheOrder.removeFirst()
            if let removed = cache.removeValue(forKey: oldest) { cacheBytes -= removed.byteCost }
        }
    }

    private func touch(_ key: FileKey) {
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
    }

    private func fail(_ failure: Error, generation: UUID) {
        guard self.generation == generation else { return }
        error = "Could not analyse audio: \(failure.localizedDescription)"
        loading = false
        analysisTask = nil
    }
}

private struct FileKey: Hashable {
    let url: URL
    let size: Int64
    let modified: Date

    init(url: URL) throws {
        let url = url.standardizedFileURL
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize,
              let modified = values.contentModificationDate else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        self.url = url
        self.size = Int64(size)
        self.modified = modified
    }
}

/// 24 quantised values per frame keep multi-hour files small in the in-memory cache.
private struct AudioAnalysis {
    let startTime: Double
    let frameInterval: Double
    let values: [UInt8]
    let frameCount: Int
    var byteCost: Int { values.count }

    func bands(at time: Double) -> [Float] {
        guard frameCount > 0 else { return [Float](repeating: 0, count: 24) }
        let position = min(max((time - startTime) / frameInterval, 0), Double(frameCount - 1))
        let index = Int(floor(position))
        let next = min(index + 1, frameCount - 1)
        let fraction = Float(position - Double(index))
        func smoothed(_ frame: Int, band: Int) -> Float {
            let previous = max(0, frame - 1), following = min(frameCount - 1, frame + 1)
            return (Float(values[previous * 24 + band]) + 2 * Float(values[frame * 24 + band]) + Float(values[following * 24 + band])) / (4 * 255)
        }
        return (0..<24).map { band in
            let first = smoothed(index, band: band)
            return first + (smoothed(next, band: band) - first) * fraction
        }
    }

    static func read(url: URL, onProgress: @escaping @Sendable (AudioAnalysis) async -> Void) async throws -> AudioAnalysis {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return AudioAnalysis(startTime: 0, frameInterval: 1, values: [], frameCount: 0)
        }
        try Task.checkCancellation()
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AudioAnalysisError.readerFailed }

        var analyser: AudioSpectrumAnalyser?
        var firstTime: Double = 0
        var outputValues: [UInt8] = []
        var lastPublishedFrame = 0
        do {
            while let buffer = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let format = CMSampleBufferGetFormatDescription(buffer),
                      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                      asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0,
                      let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                if analyser == nil {
                    analyser = try AudioSpectrumAnalyser(sampleRate: asbd.mSampleRate)
                    let timestamp = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                    firstTime = timestamp.isFinite ? max(0, timestamp) : 0
                }
                let byteCount = CMBlockBufferGetDataLength(block)
                guard byteCount >= MemoryLayout<Float>.size else { continue }
                var samples = [Float](repeating: 0, count: byteCount / MemoryLayout<Float>.size)
                let copyStatus = samples.withUnsafeMutableBytes { bytes in
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount, destination: bytes.baseAddress!)
                }
                guard copyStatus == noErr else { throw AudioAnalysisError.invalidSampleData }
                analyser?.append(samples: samples, channels: Int(asbd.mChannelsPerFrame), into: &outputValues)
                let frameCount = outputValues.count / 24
                // Show the first few seconds promptly, then refresh through the rest of the file.
                let nextInterval = lastPublishedFrame == 0 ? 36 : 90
                if frameCount - lastPublishedFrame >= nextInterval, let analyser {
                    try Task.checkCancellation()
                    await onProgress(AudioAnalysis(startTime: firstTime + analyser.firstFrameOffset,
                                                   frameInterval: analyser.frameInterval,
                                                   values: outputValues,
                                                   frameCount: frameCount))
                    lastPublishedFrame = frameCount
                }
            }
            try Task.checkCancellation()
            if reader.status == .failed { throw reader.error ?? AudioAnalysisError.readerFailed }
            analyser?.finish(into: &outputValues)
        } catch {
            reader.cancelReading()
            throw error
        }
        let frameCount = outputValues.count / 24
        return AudioAnalysis(startTime: firstTime + (analyser?.firstFrameOffset ?? 0),
                             frameInterval: analyser?.frameInterval ?? 1,
                             values: outputValues,
                             frameCount: frameCount)
    }
}

private enum AudioAnalysisError: Error {
    case readerFailed
    case invalidSampleData
    case fftUnavailable
}

/// A rolling Hann-windowed FFT sampled about 18 times per second.
private final class AudioSpectrumAnalyser {
    private let fftSize = 4096
    private let bands = 24
    private let sampleRate: Double
    private let hopSize: Int
    private let setup: vDSP_DFT_Setup
    private let window: [Float]
    private let windowSum: Float
    private var ring = [Float](repeating: 0, count: 4096)
    private var writeIndex = 0
    private var received = 0
    private var sinceLastFrame = 0
    private var emitted = 0

    var frameInterval: Double { Double(hopSize) / sampleRate }
    var firstFrameOffset: Double { Double(min(received, fftSize)) / sampleRate / 2 }

    init(sampleRate: Double) throws {
        self.sampleRate = sampleRate
        hopSize = min(4096, max(1, Int((sampleRate / 18).rounded())))
        guard let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD) else {
            throw AudioAnalysisError.fftUnavailable
        }
        self.setup = setup
        let size = 4096
        window = (0..<size).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(size - 1)) }
        windowSum = window.reduce(0, +)
    }

    deinit { vDSP_DFT_DestroySetup(setup) }

    func append(samples: [Float], channels: Int, into values: inout [UInt8]) {
        guard channels > 0 else { return }
        let sampleFrames = samples.count / channels
        for frame in 0..<sampleFrames {
            var mono: Float = 0
            for channel in 0..<channels { mono += samples[frame * channels + channel] }
            mono /= Float(channels)
            ring[writeIndex] = mono.isFinite ? mono : 0
            writeIndex = (writeIndex + 1) % fftSize
            received += 1
            sinceLastFrame += 1
            if received >= fftSize && (emitted == 0 || sinceLastFrame >= hopSize) {
                analyse(into: &values)
                emitted += 1
                sinceLastFrame = 0
            }
        }
    }

    func finish(into values: inout [UInt8]) {
        // Short clips still get one real frame, padded only after their final sample.
        if emitted == 0 && received > 0 { analyse(into: &values) }
    }

    private func analyse(into values: inout [UInt8]) {
        var real = [Float](repeating: 0, count: fftSize)
        var imaginary = [Float](repeating: 0, count: fftSize)
        var resultReal = [Float](repeating: 0, count: fftSize)
        var resultImaginary = [Float](repeating: 0, count: fftSize)
        var rms: Float = 0
        let available = min(received, fftSize)
        let first = received < fftSize ? 0 : writeIndex
        for i in 0..<available {
            let sample = ring[(first + i) % fftSize]
            rms += sample * sample
            real[i] = sample * window[i]
        }
        rms = sqrt(rms / Float(max(available, 1)))
        if rms < 0.0001 {
            values.append(contentsOf: repeatElement(0, count: bands))
            return
        }
        vDSP_DFT_Execute(setup, &real, &imaginary, &resultReal, &resultImaginary)
        let nyquist = sampleRate / 2
        let upper = min(18_000, nyquist)
        for band in 0..<bands {
            let lowerFrequency = 35 * pow(upper / 35, Double(band) / Double(bands))
            let upperFrequency = 35 * pow(upper / 35, Double(band + 1) / Double(bands))
            let lowerBin = max(1, Int(floor(lowerFrequency * Double(fftSize) / sampleRate)))
            let upperBin = min(fftSize / 2, max(lowerBin, Int(ceil(upperFrequency * Double(fftSize) / sampleRate))))
            var energy: Float = 0
            for bin in lowerBin...upperBin {
                let re = resultReal[bin]
                let im = resultImaginary[bin]
                energy += re * re + im * im
            }
            let magnitude = sqrt(energy / Float(upperBin - lowerBin + 1)) * 2 / windowSum
            let level = min(1, pow(max(0, magnitude * 4), 0.65))
            values.append(UInt8((level * 255).rounded()))
        }
    }
}
