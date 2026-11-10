import Foundation

// Route copy workers before SwiftUI initializes NSApplication or any app state.
// Only the foreground process creates windows, menus, and download controls.
let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--copy-helper"), arguments.count > index + 1,
   let rootIndex = arguments.firstIndex(of: "--media-root"), arguments.count > rootIndex + 1 {
    BackgroundCopier.run(kind: arguments[index + 1], root: URL(fileURLWithPath: arguments[rootIndex + 1]))
} else {
    SaveTubeApp.main()
}
