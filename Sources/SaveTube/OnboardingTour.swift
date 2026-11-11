import SwiftUI

/// A short, in-window guide. Finishing or skipping records completion in the root view.
struct OnboardingTour: View {
    let onFinish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = 0
    @State private var direction: CGFloat = 1

    private struct Page {
        let title: String
        let detail: String
        let instruction: String
    }
    private let pages = [
        Page(title: "Save a video or song", detail: "Paste a link, choose MP4, MP3, or Both, then select Download.", instruction: "Your download appears in the library below."),
        Page(title: "Keep your library tidy", detail: "Create folders, import files you already have, and move or rename items from the library.", instruction: "Double-click a file to play it here; open Player for the full view."),
        Page(title: "Listen and watch", detail: "Open Player for your queue, artwork, and audio visualizer. Use Space to pause or resume.", instruction: "The mini player keeps playback in reach while you browse."),
        Page(title: "Make it yours", detail: "Open Settings to change the window background or build a palette from an image with Matugen.", instruction: "You can replay this tour from the Help menu.")
    ]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.78).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("MediaFetch").font(.system(size: 15, weight: .bold, design: .rounded))
                        Spacer()
                        Text("\(step + 1) of \(pages.count)")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.56))
                    }
                    .padding(.bottom, 20)

                    ZStack {
                        pageContent
                            .id(step)
                            .transition(reduceMotion ? .opacity : .opacity
                                .combined(with: .scale(scale: 0.97))
                                .combined(with: .offset(x: direction * 24)))
                    }
                    .frame(maxWidth: .infinity)

                    HStack(spacing: 6) {
                        ForEach(pages.indices, id: \.self) { index in
                            Capsule()
                                .fill(index == step ? Color(red: 0.54, green: 0.72, blue: 1) : .white.opacity(0.18))
                                .frame(width: index == step ? 30 : 12, height: 5)
                        }
                        Spacer()
                    }
                    .padding(.top, 26)
                    .padding(.bottom, 25)

                    HStack(spacing: 12) {
                        Button("Skip tour", action: onFinish)
                            .buttonStyle(.plain)
                            .foregroundStyle(.white.opacity(0.6))
                        Spacer()
                        if step > 0 {
                            Button("Back") { changeStep(to: step - 1) }
                                .buttonStyle(ClearGlassButtonStyle())
                        }
                        Button(step == pages.count - 1 ? "Start using MediaFetch" : "Next") {
                            if step == pages.count - 1 { onFinish() }
                            else { changeStep(to: step + 1) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 0.54, green: 0.72, blue: 1))
                        .keyboardShortcut(.defaultAction)
                    }
                    .controlSize(.large)
                }
                .padding(28)
                .frame(width: min(540, geometry.size.width - 48))
                .background(RoundedRectangle(cornerRadius: 26).fill(Color(red: 0.09, green: 0.11, blue: 0.15).opacity(0.7)))
                .modifier(ClearGlassControl(radius: 26, panel: true))
                .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(.white.opacity(0.14)))
                .shadow(color: .black.opacity(0.55), radius: 30, y: 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onExitCommand(perform: onFinish)
        .animation(reduceMotion ? nil : .spring(response: 0.33, dampingFraction: 0.88), value: step)
        .accessibilityAddTraits(.isModal)
    }

    private var pageContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            illustration
                .frame(height: 152)
                .padding(.bottom, 22)
            Text(pages[step].title)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.bottom, 10)
            Text(pages[step].detail)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)
            Text(pages[step].instruction)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(red: 0.65, green: 0.79, blue: 1))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var illustration: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(LinearGradient(colors: [Color(red: 0.12, green: 0.17, blue: 0.25),
                                              Color(red: 0.08, green: 0.10, blue: 0.15)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.08))
            switch step {
            case 0:
                VStack(spacing: 14) {
                    HStack(spacing: 10) {
                        Image(systemName: "link").foregroundStyle(.white.opacity(0.6))
                        Text("Paste a video link…").foregroundStyle(.white.opacity(0.6))
                        Spacer()
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color(red: 0.54, green: 0.72, blue: 1))
                    }
                    .font(.system(size: 14))
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.08)))
                    HStack(spacing: 8) {
                        formatChip("MP4")
                        formatChip("MP3")
                        formatChip("Both")
                        Spacer()
                    }
                }.padding(23)
            case 1:
                VStack(alignment: .leading, spacing: 13) {
                    folderRow("Music", symbol: "music.note", count: "12")
                    folderRow("Videos", symbol: "play.rectangle", count: "4")
                }.padding(.horizontal, 26)
            case 2:
                HStack(spacing: 22) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 66, weight: .ultraLight))
                        .foregroundStyle(Color(red: 0.54, green: 0.72, blue: 1))
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Now Playing").font(.system(size: 17, weight: .semibold, design: .rounded))
                        Image(systemName: "waveform")
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(.white.opacity(0.62))
                    }
                    Spacer()
                }.padding(.horizontal, 34)
            default:
                HStack(spacing: 20) {
                    Image(systemName: "paintpalette.fill")
                        .font(.system(size: 49))
                        .foregroundStyle(.white.opacity(0.85))
                    HStack(spacing: -8) {
                        Circle().fill(Color(red: 0.43, green: 0.58, blue: 0.92))
                        Circle().fill(Color(red: 0.78, green: 0.53, blue: 0.71))
                        Circle().fill(Color(red: 0.52, green: 0.74, blue: 0.65))
                    }.frame(width: 138, height: 48)
                    Spacer()
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 24))
                        .foregroundStyle(.white.opacity(0.58))
                }.padding(.horizontal, 30)
            }
        }
    }

    private func formatChip(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(.white.opacity(text == "MP4" ? 0.18 : 0.07)))
    }

    private func folderRow(_ title: String, symbol: String, count: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(Color(red: 0.54, green: 0.72, blue: 1))
            Text(title).font(.system(size: 14, weight: .medium))
            Spacer()
            Text(count).foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 11).fill(.white.opacity(0.07)))
    }

    private func changeStep(to next: Int) {
        direction = next > step ? 1 : -1
        step = next
    }
}
