# Validation and distribution

Build locally with `./scripts/build-app.sh`. `SKIP_HELPERS=1` creates a lightweight
UI-only development bundle; do not distribute that variant as self-contained.
The build uses Swift Package Manager and Command Line Tools, with no Xcode project.

Release builds bundle the official yt-dlp macOS executable (2026.10.26) and the
native FFmpeg/ffprobe 8.0.1 executables compiled from official FFmpeg and LAME
3.100 source archives with no nonfree components. Every
download, including cache hits, is SHA-256 checked against pinned release asset
digests. FFmpeg and LAME source archives, exact build commands, and license
notices are bundled in Resources/Sources for rebuilding. No system
Python, Homebrew or Rosetta is required for the Apple Silicon package.
They also bundle native Matugen 4.2.0 for wallpaper palettes and the official
Deno 2.9.8 executable for yt-dlp's JavaScript challenge solver. Matugen's
upstream source, locked vendored dependencies, license notices, and offline
rebuild instructions ship in Resources/Sources. Deno retains its upstream
code signature and JIT entitlements; its pinned binary checksum, license,
dependency lockfile, and provenance are included in the bundle.

The app and most bundled helpers are ad-hoc signed; Deno retains its upstream
signature and entitlements. The app is not Developer ID signed
or notarized; a downloaded release can require macOS's Open Anyway action.
The script targets the current machine architecture; the initial release and
the macos-15 CI job build Apple Silicon. Intel is supported by the script when
run on an Intel Mac but must be tested separately before an Intel release.
The first build compiles media helpers and can take several minutes; subsequent
builds reuse the architecture-specific helper cache. FFmpeg intentionally enables
common audio decoders and MP4/MP3 remuxing/conversion used by SaveTube, rather
than every codec in a general-purpose FFmpeg installation.

## Required release checks

- Run a release build and `codesign --verify --deep --strict dist/SaveTube.app`.
- Run `./scripts/test-theme.sh` and check Matugen palette generation.
- Launch the packaged app; check URL input, Paste, both selectors, Open Folder,
  search, folder creation/rename/removal, assignment, and file open/reveal/Trash.
- Exercise MP4, MP3 and Both against media you are permitted to download.
- Confirm cancellation leaves resumable parts; retry resumes and displays errors.
- Confirm library metadata survives quitting and reopening the app.
- Confirm helpers run without Homebrew/Python and conversion uses bundled FFmpeg.

This checklist is a release procedure, not a claim that all checks have passed.
Record actual executed checks in the release notes.

## Executed helper checks (2026-11-10)

- Compiled FFmpeg 8.0.1 and LAME 3.100 natively on Apple Silicon.
- `otool -L` confirmed ffmpeg/ffprobe link only system libraries/frameworks.
- Converted generated AAC audio to 192 kbit/s MP3; ffprobe read duration correctly.
- Remuxed generated H.264/AAC video to MP4 with stream copy; ffprobe confirmed
  H.264 and AAC streams.
- Ran official bundled yt-dlp executable: version `2026.10.26`.
- Shell syntax check passed for the build script.

GitHub Actions uses manual dispatch and uploads a build artifact. Publishing a
GitHub Release is a separate explicit `gh release create` operation.

## Executed application checks (2026-11-10)

- Release Swift build, app/helper ad-hoc signing, signature verification, and ZIP creation passed on Apple Silicon.
- Five isolated core suites passed: library persistence, history migration, bookmark tracking/file operations, asynchronous imports, and both background copier processes.
- Mock download suite passed URL validation, format sequencing, progress, errors, retry, and cancellation including child-process termination.
- Real localhost fixture download through the bundled yt-dlp passed for Both; bundled FFmpeg extracted MP3 and bundled ffprobe verified H.264/AAC MP4 plus MP3.
- Native UI checks verified dragging the segmented bubble in both directions changes selected options, immersive window chrome, Settings controls, background selection, in-window Settings drawer, Matugen missing-CLI feedback, and themed folder creation/deletion. The temporary UI folder was removed afterward.
- Native glass implementation follows Apple's custom-view guide: interactive clear material, a shared effect container for segmented selection, stable glass identity, and expansion geometry applied before material rendering. Labels belong to their glass view to avoid being sampled as blurred background content.
- Native Matugen 4.2.0 built on Apple Silicon with Rust/Cargo 1.91.0 and macOS 13 deployment target. Its `otool -L` output lists only system libraries; the complete source archive contains vendored dependencies and offline build configuration. `./scripts/test-theme.sh` passed palette variants, preference persistence, and real bundled Matugen generation from a generated PNG.
- Official Deno 2.9.8 passed strict code signature verification and ran JavaScript with the bundled helper directory as the only non-system PATH entry. Its signature contains JIT entitlements. yt-dlp reported `JS runtimes: deno-2.9.8` and used `[jsc:deno]` to solve a YouTube JavaScript challenge in a simulation without downloading media.

## Scope and remaining platform limits

The release targets Apple Silicon/macOS 13+. Native Apple Liquid Glass requires macOS 26+; earlier systems use the custom fallback. The window backdrop deliberately retains mild frosting/darkening; controls use clear glass. The app is ad-hoc signed and unnotarized. External move tracking supports same-volume moves and renames; cross-volume replacement may require importing again. Imports accept MP3/MP4; normal media imports copy/hash off the main thread, while one-time legacy-history import is synchronous. Real third-party YouTube downloads were not part of the localhost fixture test and may depend on website restrictions or extractor changes.

Reference: https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views

## Native Music-style interface and playback checks

The final interface uses NavigationSplitView, a system sidebar/List/toolbar/search,
SF Symbols, asynchronous embedded artwork/video thumbnails, and a persistent
MiniPlayer. Play/Shuffle, double-click, or Return starts native AVPlayer playback;
Now Playing uses AVPlayerView for video. System media commands and Now Playing
metadata are integrated.

`./scripts/test-playback.sh` passed real generated MP3/MP4 AVPlayer loading,
duration, time advance, pause, seeking, next/previous queue navigation, missing-file
handling, and complete stop/reset. The check uses silent/isolated generated media.
A packaged UI smoke check imported a silent MP3, started playback, displayed the
MiniPlayer, expanded Now Playing, changed its seek slider, and moved the temporary
fixture to Trash. The original Python app was also launched separately at the
user's request; it is not part of the Swift runtime.

The Matugen path now normalizes wallpaper images with ImageIO before generation,
including macOS HEIC wallpapers; native palette-generation tests still pass.
Design research used Apple's Music user guides and native sidebar/material HIG:
https://support.apple.com/en-gb/guide/iphone/ipha4521ef7d/27/ios
https://developer.apple.com/design/human-interface-guidelines/sidebars
https://developer.apple.com/design/human-interface-guidelines/materials

## Version 1.1: dedicated downloader and detail-pane player

The app now opens the restored centered downloader, with a bottom clear-glass
Downloader/Player selection bar. The downloader's URL, format, filter, and search
are kept in shared view state across page changes. Player retains the Music-style
library; its MiniPlayer and page bar are inset within the detail column. Expanded
Now Playing replaces the detail content rather than opening a window-modal sheet.
The sidebar remains usable, and playback continues across page navigation.

The expanded player adds metadata titles/artists, favorites, shuffle/repeat,
editable queue, and native AVRoutePickerView routing. AVPlayer playback checks now
cover embedded metadata, shuffle restoration, repeat cycling/wrap, queue editing,
and favorite toggles in addition to the prior playback checks.

`test-visualizer.sh` passed generated silent MP3, tonal MP3, MP4 AAC audio, a file
changing from silence to tone over time, and cached switching. Visualization uses
24 frequency bands from cancellable AVAssetReader/Accelerate analysis, not an
unrelated animation or playback tap. `test-palette.sh` passed embedded-artwork
color extraction, artwork precedence, and wallpaper-color fallback with controlled
local fixtures. Native ImageIO supports wallpaper formats such as HEIC.

A packaged UI smoke check verified Downloader as the landing page; link retention
across tabs; MiniPlayer staying inside the right pane; expanded Now Playing and
Playing Next occupying that pane with no modal sheet; and sidebar navigation while
expanded playback was visible. The synthetic silent layout-check file was moved
to Trash afterward; the user's existing library media was preserved.

Design references include Apple's mobile Music guides and the BitChord upstream
repository (read-only research; no third-party code or artwork was copied):
https://support.apple.com/en-gb/guide/iphone/iph676daac9b/ios
https://github.com/kushagrasinghx/BitChord

## Version 1.1.1: navigation and interaction polish

Both workspaces mount at startup and retain their view state. Page changes use a
short slide/fade; inactive visualizer timelines pause. Downloader chrome is managed
at the window root, without a bottom navigation inset. The titlebar stays transparent
and its toolbar is hidden in Downloader mode.

The selection lens contains no labels: stationary text is drawn separately above
native clear glass. Mouse-down expands the lens before dragging; bounded edge drag
adds small elastic offsets. Expanded player collapse has a 72-point hit target.
Player controls and Settings use larger, consistent glass hit areas. Audio bands
use adjacent-frame interpolation and temporal smoothing; artwork/wallpaper pools
move on a 24 fps backdrop, with static positions under Reduce Motion.

Downloader file rows now show artwork, media details, folder counts, and glass
hover/selection. Filtering clears selections; hidden files cannot remain action
targets, and empty results are displayed over the list. Space toggles playback in
the active workspace outside text editing and dialogs; autorepeat is consumed.

The visualizer fixture checks and complete Swift source typecheck passed during
this polish. A packaged UI check verified the top navigation, full-bleed Downloader,
right-pane player expansion, and collapsing by clicking the outer glass button
away from its chevron. Existing media was preserved.

The Downloader also provides a compact playback bar with transport and seeking;
files play there without switching workspaces. Its custom row selection replaces
native List selection so only the rounded glass row is highlighted. A first-run,
replayable guided tour explains downloading, files, playback, and appearance with
animated cards and a reduced-motion alternative.

Packaged keyboard checks confirmed Space paused in Player, resumed from Downloader,
and remained a literal space while typing a two-word search without pausing audio.

## MediaFetch 1.2

SaveTube's visible app name and distribution bundle are now MediaFetch. The bundle
identifier, persisted settings keys and media directory are intentionally retained.
The app ships as `MediaFetch.app` with matching ZIP/checksum names.

Validation passed for playback preparation/pause/resume and structural-only player
updates (clock ticks do not notify the large presentation views), core library and
file operations, mock download sequencing/cancellation, real local HTTP MP4 + MP3
conversion, bundled Matugen, palette/custom artwork/sidecar precedence, invalid
artwork preservation, and visualizer fixtures. The added artwork checks exercise
4096-pixel source images, exact 128/1024-pixel presentation copies, and shared-request
cancellation. These are functional tests, not a whole-process memory benchmark.

Artwork decode work is limited to three concurrent tasks with per-consumer
cancellation. NSCache has a 64 MiB decoded-cost target and 64 entries; audio analysis
retains at most four cached analyses within 32 MiB, plus any active analysis.
NSCache limits are eviction targets, not a total-process RAM ceiling. Visible canvas
animations request 60 Hz; native effects follow system rendering. Hardware-specific
frame pacing, VoiceOver and Instruments stress profiling remain separate checks.

See `CODE_AUDIT.md` and `POLISH_REPORT.md` for coverage, fixes, remaining validation
and the proposed feature roadmap. No quantified whole-app RAM reduction or measured
60 FPS guarantee is asserted by these source and fixture checks.

## Final 1.2 UI verification — 12 November 2026

Production build, deep signature and ZIP integrity checks passed. The shared header
was checked with the compact Actions fallback. Empty-padding clicks in the page
switch, Help and Actions controls worked, and the asynchronous import sheet opened
and canceled successfully.

The spectrum was traced against a real MP3: its analyser returned nonzero data,
but the previous view remained flat. The small spectrum view now observes playback
and advances from the TimelineView date; analysis also publishes early partial
results. In the rebuilt app, the track continued playing and different nonzero band
shapes were visible at 8 and 37 seconds. The loading label cleared after analysis.
The expanded player showed the revised full-pane artwork-colour fields and native
AirPlay control. Palette fixtures cover vivid single-colour and neutral gray, black
and white images; the visualizer fixture checks partial output during long-file
analysis and clearing that output when tracks change.

Minimum-window geometry, VoiceOver and Instruments profiling remain unverified.
