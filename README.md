# SaveTube for macOS

A native Swift media library and MP4/MP3 downloader, with an Apple Music-inspired sidebar, artwork-led rows, in-app AVKit playback, a floating MiniPlayer, and an immersive window. Native Apple Liquid Glass is available on macOS 26+; earlier systems use the custom fallback.

## Install

Download the ZIP from [Releases](https://github.com/56Mugiwara/Savetube/releases), unzip it, and move **SaveTube.app** to Applications. The current build supports **Apple silicon, macOS 13 or later**.

The app bundles yt-dlp, FFmpeg, ffprobe, Deno, and Matugen. No Python, Homebrew, Rust, or separate helper installation is required to run it. The app is ad-hoc signed and is not Apple notarized. macOS may require allowing it in System Settings → Privacy & Security after the first launch attempt. Deno retains its upstream signature and JIT entitlements.

## Library and playback

- Browse All Media, Music, Videos, and Recently Added in the native sidebar. Search from the toolbar.
- Import MP3 music and MP4 videos with **Import**, or drop them onto the library or a folder. Import copies the original files.
- Create a folder from the sidebar. In All Media, folder disclosure arrows show or hide their tracks. Add tracks through drag-and-drop or their context menu.
- Double-click a row, choose Play from its menu, or use the library Play/Shuffle controls. Playback stays inside SaveTube.
- The floating MiniPlayer opens Now Playing, with seeking, volume, previous/next, and AVKit video playback. macOS media keys and Now Playing controls are supported.
- Embedded audio artwork and video thumbnails are loaded asynchronously, with neutral media icons as fallbacks.

Folders are virtual collections: adding a file to one does not move the underlying file on disk.

## Download

Open **Download** in the toolbar, paste a URL, and choose MP4, MP3, or Both. The selection bubble supports dragging, expands during the gesture, and springs into the nearest option. Download progress stays visible in the library.

Command-period cancels a download. Shift-Command-R retries the previous download; partial files resume when supported. Video IDs in filenames prevent same-title collisions, and completed IDs are archived per format to avoid repeat downloads. Website availability and restrictions can affect downloading. Only save media you have permission to download.

## File management and history

Rename, Move File, Show in Finder, and Move to Trash are available from each media row's menu. The toolbar also offers Delete for the selected file or folder. Native bookmarks follow same-volume Finder moves/renames and retain folder membership across restarts. Operations resolve the current tracked path before acting. Files on disconnected disks remain recorded; cross-volume replacements may require importing again.

Deleting a folder can keep its media or move the media to Finder Trash. Independently copied files in Downloads remain separate.

Media and metadata persist outside the app at `~/Library/Application Support/SaveTube/Media/`. MP3/MP4 files are the history; `.library.json` holds collections, and `.tracked-files.json` holds native file bookmarks.

Two native Swift background processes start with SaveTube, monitor completed MP3/MP4 files, and copy them into Downloads. They stop when the app quits. Existing files are preserved, collisions get numbered suffixes, and persistent hashes avoid repeat copies after relaunch.

Choose **File → Import Existing History…** to copy an older `.Dmp3`, `.Dmp4`, and `.library.json` installation into the native library. The original files remain untouched.

## Appearance

Open the in-window **Settings** panel from the gear button or Command-comma:

- Monochrome, wallpaper tint, or an imported Matugen JSON palette.
- Bundled Matugen generation from wallpaper or a chosen image; optional regeneration after wallpaper changes.
- Black canvas or a dark, lightly frosted desktop backdrop, with an adjustable Background Opacity slider.

Controls use clear native Liquid Glass on supported macOS versions, with labels placed inside the effect to keep them crisp. Panels use a restrained dark tint. Selection, disclosure, player, and dialog motion respect Reduce Motion. Matugen uses dry-run mode: it does not change the wallpaper or run user templates/hooks. ImageIO normalizes wallpaper formats such as HEIC before palette generation.

## Build and checks

Requires macOS, a Swift toolchain with a macOS 26 SDK, curl, make, pkg-config, and standard build tools. Full Xcode is optional. Rust is bootstrapped into the project cache for Matugen; nothing is installed globally.

```sh
./scripts/build-app.sh
./scripts/test-core.sh
./scripts/test-downloads.sh
./scripts/test-downloads.sh --real
./scripts/test-playback.sh
./scripts/test-theme.sh
```

The build verifies pinned downloads, compiles static FFmpeg/LAME and native Matugen, bundles signed Deno, verifies the app signature, and creates `dist/SaveTube.app`, a ZIP, and a SHA256 checksum. The first build takes longer. GitHub Actions supports manual builds.

Tests use generated local media and isolated temporary directories. See [validation notes](docs/VALIDATION.md) for executed checks and platform limits. `SAVETUBE_DATA_DIR` and `SAVETUBE_DOWNLOADS_DIR` override data paths for development. `SKIP_HELPERS=1` makes a development-only bundle.

## Sources and licenses

The app and background copy workers are Swift. The three supplied Python files remain under `Reference/` for comparison and are never executed by the app. Copy workers use `--copy-helper MP3` and `--copy-helper MP4` modes of the native executable, routed before SwiftUI initializes.

The repository's GPLv3 license is retained. Helper licenses, FFmpeg/LAME source archives, full Matugen source with locked vendored dependencies, and build instructions ship in Resources. Third-party standalone tools remain separate executables.
