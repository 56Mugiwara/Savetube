import SwiftUI

/// Short text guide shared by the downloader and player screens.
struct HelpSummary: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MediaFetch Help")
                .font(.headline)

            Text("Download one video or audio URL at a time with yt-dlp. Examples include YouTube, SoundCloud and TikTok; site support can vary.")

            Text("Paste a link, choose MP4, MP3 or Both, then Download. Import local files and organize your library with folders, rename, move and trash.")

            Text("Choose custom artwork from a file; Reset Artwork restores the original. In Player, use Space to pause or resume, drag the seek bar, or expand the mini player.")

            Text("Settings includes appearance and Matugen palette options.")

            Link("yt-dlp supported sites", destination: URL(string: "https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md")!)
                .font(.callout)
        }
        .font(.callout)
        .frame(width: 320, alignment: .leading)
        .padding(18)
        .textSelection(.enabled)
    }
}
