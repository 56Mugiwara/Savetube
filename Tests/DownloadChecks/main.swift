import Foundation
import Combine

@main
struct DownloadChecks {
    @MainActor static func main() {
        let engine = DownloadEngine()
        let args = CommandLine.arguments
        guard args.count >= 3 else { fatalError("Usage: DownloadChecks DESTINATION URL [--real]") }
        let destination = URL(fileURLWithPath: args[1])
        let url = args[2]
        let real = args.contains("--real")
        engine.start(url: "file:///etc/passwd", format: "MP4", destination: destination) {}
        precondition(!engine.isRunning && engine.status.contains("valid HTTP"))
        engine.start(url: url, format: "Both", destination: destination) {
            precondition(!engine.isRunning && engine.progress == 1 && engine.status == "Download success", engine.status)
            for kind in ["MP4", "MP3"] {
                let files = try! FileManager.default.contentsOfDirectory(at: destination.appendingPathComponent(kind), includingPropertiesForKeys: nil)
                precondition(files.contains { $0.pathExtension.lowercased() == kind.lowercased() }, "Missing \(kind)")
            }
            if real {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    precondition(engine.progress == 0 && engine.status == "Download success")
                    print("PASS: real yt-dlp MP4 download + FFmpeg MP3 extraction + progress clearing")
                    exit(0)
                }
                return
            }
            engine.start(url: "https://example.invalid/failure", format: "MP4", destination: destination) {
                precondition(engine.status.contains("Test extractor failure"), engine.status)
                precondition(engine.progress == 0)
                engine.retry {
                    precondition(engine.status.contains("Test extractor failure"))
                    engine.start(url: "https://example.invalid/cancel", format: "MP4", destination: destination) {
                        precondition(engine.status.contains("cancelled"), engine.status)
                        print("PASS: URL validation, Both sequencing, progress, failure propagation, retry, cancellation")
                        exit(0)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { engine.cancel() }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { print("FAIL: timeout"); engine.cancel(); exit(1) }
        RunLoop.main.run()
    }
}
