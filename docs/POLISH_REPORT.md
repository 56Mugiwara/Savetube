# MediaFetch codebase audit

**Scope:** source review of the working tree on 2026-11-11, including the MediaFetch 1.2.0 integration changes. The published baseline is `b4850d0`; this report describes the current source, not a verified release artifact. The original audit was read-only; follow-up implementation and focused checks are recorded under the findings they address. Findings are concrete issues or review risks, not a claim that every defect has been found.

## Findings

### P2 — asynchronous image work can outlive the view that requested it

**Status: Fixed in source; runtime profiling pending.** Artwork requests now share an in-flight decode by source signature and pixel bucket, track each waiter independently, and cancel the worker only after its final consumer cancels. A cancellation-safe FIFO permit actor limits active artwork decodes to three; canceled waiters are removed from its queue, and abandoned queued work does not start. Existing pixel buckets, downsampling, and cache cost/count limits remain. Palette preparation now wraps its detached worker in `withTaskCancellationHandler`, cancels that worker when a newer request takes over, and checks cancellation around cache access, media/wallpaper loads, sampling, and cache insertion. Video image generation also cancels AVAssetImageGenerator work when canceled.

**Validation:** focused Swift typechecking passed for the artwork/palette/player source group; `scripts/test-artwork.sh`, `scripts/test-palette.sh`, and `scripts/test-visualizer.sh` passed. The artwork fixture checks 128- and 1024-pixel output representations from a generated 4096-pixel source and verifies that one canceled consumer does not prevent a same-key waiter from receiving the result. This exercises coalesced cancellation and downsampling, but not the maximum concurrent worker count under load. Fast-scroll cancellation, rapid-track replacement, actual process RAM, and frame pacing still require a running app and Instruments. Do not infer measured performance from cache limits or the permit count alone.

### P3 — bundled helper fallback accepts executables from inherited `PATH`

**Status: Fixed in the current tree; packaged validation required.** The reviewed baseline could search inherited `PATH` when a bundled helper was missing. App bundles now resolve yt-dlp, FFmpeg and Matugen only from `Contents/Helpers`; a missing bundled tool produces an actionable error instead of silently using a substitute. The downloader subprocess also receives a restricted helper/system PATH. Command-line developer builds retain their toolchain lookup.

**Validation:** download fixtures (sequencing, progress, retry, cancellation) and real bundled Matugen generation pass. Final packaged helper/signature checks are recorded in the release validation section.

## Area review

### Playback and navigation

Playback ownership is centralized in `PlaybackStore`; observers are removed/replaced when items change, stale item callbacks compare identity, queue stepping skips unreadable items, and playback state is separated from the 4 Hz presentation clock (`PlaybackStore.swift:63-70, 158-203`; `NativeLibraryView.swift:25-29`; `DownloaderMiniPlayer.swift:76-88`). The root intentionally keeps Downloader and Player views mounted and gates active work and accessibility/hit testing (`SaveTubeRootView.swift:19-45`). The previously identified hidden-page Delete-command risk is **Fixed in the current tree**: handlers now gate on active page and modal/player state (`DownloadHomeView.swift:223-226`, `NativeLibraryView.swift:284-287`). Native focused buttons/sliders/segmented controls are exempted from the local key monitor (`LibraryKeyboard.swift:39-51`); verify arrow, Return, and Space behavior against both focused controls and list navigation in the built app.

No source-level playback race was confirmed. Item status and end notifications guard against stale player items; one practical follow-up is manual testing of rapid next/previous, pause while preparing, file removal during playback, and route changes. The audio visualizer cancels the prior analysis task and checks cancellation during sample-buffer reads, with a 32 MiB analysis cache (`AudioVisualizationStore.swift:19-62, 145-190`); cancellation and cache behavior were reviewed structurally, not benchmarked.

### Memory, artwork, and palette work

Artwork is downsampled through ImageIO or AVAssetImageGenerator, cached with a 64 MiB cost target, and deduplicated for identical in-flight keys (`MediaArtwork.swift:47-100, 105-144`). Active decode work has a three-permit bound with cancellable waiters; individual view cancellation releases only its own consumer, leaving a shared decode alive for remaining waiters (`MediaArtwork.swift:62-167, 195-235`). Custom artwork is copied into the app library, validated by ImageIO, persisted by stable file identity, and takes precedence over adjacent download thumbnails (`ArtworkOverrides.swift:28-54, 67-115`). The palette cache stores only small color samples and evicts over 32 keys (`MediaPaletteStore.swift:81-101`). These limits bound this component's concurrent decodes and retained cache target, not total process memory. No measured frame-rate or memory reduction is asserted.

`ArtworkOverrides` copy/clear failures now publish a readable error to the root alert. Replacement images are validated before an atomic replacement; the palette checks verify that an invalid image preserves the existing saved artwork. Invalid/unavailable embedded art falls back to video thumbnails or the file-type glyph (`MediaArtwork.swift:72-89, 118-144`), so no confirmed broken fallback was found.

### File management, import, and persistence

`LibraryStore` filters out symlink/non-regular media, tracks stable bookmarks and file identity, stages and hashes imports, atomically writes metadata, and preserves missing-file assignments for recovery (`LibraryStore.swift:90-125, 136-168, 263-288, 333-380, 479-496`). Import copies are serialized off the main thread and busy state is reference-counted. Rename validation blocks path separators and extension changes; trash errors are reported (`LibraryStore.swift:384-438`). The native importer presents a reusable sheet instead of a nested modal panel (`MediaImportPicker.swift:4-34`).

Follow-up: the separate Move File panels use synchronous `runModal()` (`DownloadHomeView.swift:366-369`, `NativeLibraryView.swift:417-419`), unlike the asynchronous import picker. Review whether sheet presentation would fit the window flow better, and manually check moves across mounted volumes; no failure was confirmed in source review. Import/drop callbacks also need manual checks for access to files from external volumes and stale folder targets after the user changes pages (`DownloadHomeView.swift:370-383`, `NativeLibraryView.swift:421-436`). These paths were not exercised in the UI.

### Downloads and helper processes

Download URLs are restricted to HTTP(S), arguments are passed directly to `Process`, yt-dlp config is disabled, output goes to format-specific folders, progress/completion is surfaced, and cancellation terminates yt-dlp children before the parent (`DownloadEngine.swift:21-65, 109-117, 129-174, 185-223`). The copy helpers reject symlinks, wait for stable size/date observations, hash before and after staging, and atomically expose completed copies (`BackgroundCopier.swift:48-100, 109-136`). The app delegate shuts helpers down on exit (`SaveTubeApp.swift:58-65`).

Operational follow-up: `BackgroundCopier` logs errors to stderr rather than the UI (`BackgroundCopier.swift:84-96, 163-166`), so a failure copying to Downloads may be invisible to an ordinary user. Consider a user-visible helper status or a diagnostics action. Verify cancellation and helper shutdown in the packaged app; static review cannot prove child-process exit behavior on every yt-dlp/FFmpeg version.

### UI, accessibility, and error handling

The app declares an 800×680 minimum window (`SaveTubeApp.swift:12-22`) and the expanded player adapts its artwork/spacing for compact geometry (`DetailNowPlayingView.swift:66-70`). A code review cannot confirm that all controls fit at that minimum, especially with the sidebar open; visual QA at 800×680 and with enlarged accessibility text remains required. The visualizer respects Reduce Motion (`DetailNowPlayingView.swift:220-223, 246-265`), and most custom controls have help or accessibility labels. Check VoiceOver order/selection announcements for the custom folder rows and toolbar buttons in a live build.

Several stateful errors are surfaced as alerts or inline messages (library, playback, download, theme). Artwork override failures now publish a readable error shown by the root alert; invalid replacements leave the existing saved artwork intact. No blanket suppression of download or library errors was found. `SettingsView` exposes background opacity only while glass is enabled and shows Matugen errors (`SettingsView.swift:33-69`).

## Coverage inventory

- **App and navigation:** `SaveTubeApp.swift`, `SaveTubeRootView.swift`, `WindowChrome.swift`, `LibraryKeyboard.swift` — window setup, commands, page gating, titlebar behavior, keyboard monitor.
- **Downloader and library UI:** `DownloadHomeView.swift`, `NativeLibraryView.swift`, `DownloaderMiniPlayer.swift`, `NativePlayerView.swift`, `DetailNowPlayingView.swift`, `HelpSummary.swift`, `OnboardingTour.swift` — page transitions, lists, dialogs, player controls, queue, compact layout, onboarding/help.
- **Media and persistence:** `LibraryStore.swift`, `MediaImportPicker.swift`, `ArtworkOverrides.swift`, `MediaArtwork.swift`, `PlaybackStore.swift`, `AudioVisualizationStore.swift`, `MediaPaletteStore.swift` — file identity, import, artwork, playback, analysis and caches.
- **Processes and appearance:** `DownloadEngine.swift`, `BackgroundCopier.swift`, `ThemeStore.swift`, `SettingsView.swift`, `GlassSurface.swift` — subprocesses, copy helpers, palette generation, glass/chrome.
- **Entrypoints/build support:** `main.swift`, `Package.swift`, `scripts/build-app.sh`, `scripts/bundle-deno.sh`, `scripts/build-matugen.sh`, `.github/workflows/release.yml` — executable entry, package configuration and packaging paths reviewed at source level.
- **Checks/docs reviewed for context:** `Tests/ThemeChecks/main.swift`, `Tests/VisualizationChecks/main.swift`, `Tests/DownloadChecks/main.swift`, `Tests/LibraryChecks/main.swift`, `Tests/PlaybackChecks/main.swift`, `Tests/PaletteChecks/main.swift`; `scripts/test-core.sh`, `scripts/test-downloads.sh`, `scripts/test-playback.sh`, `scripts/test-visualizer.sh`, `scripts/test-theme.sh`, `scripts/test-palette.sh`; `README.md`, `docs/VALIDATION.md`.

## Limits and ordered follow-up

This was source inspection only. No test commands, build, application launch, Instruments trace, accessibility inspection, mounted-volume exercise, download, or cancellation run was performed here. The parent task reports playback-intent/readiness and structural-clock checks passing; that is not evidence of UI smoothness, whole-process memory savings, or release packaging success. Re-audit the final merged tree and complete release/UI validation after the current build finishes.

1. Measure fast-scroll and rapid-track-switch behavior with Instruments; confirm actual memory and frame pacing on target hardware.
2. Verify the packaged helper paths and signatures; app-bundle lookup now excludes inherited `PATH`.
3. Verify the 800×680 layout, keyboard focus, VoiceOver, external-volume imports, and Move picker behavior in the built application.
4. Consider a diagnostics status for background-helper copy failures; artwork copy/clear failures now have a visible alert.


## Final package checkpoint

The parent completed the MediaFetch 1.2 release build, deep signature verification, ZIP integrity verification and the functional checks recorded in `VALIDATION.md`. The final compact-header/resize screenshot pass was blocked by the Mac lock screen. Publication as a final release should follow that UI check; the reports do not treat the lock-screen blocker as a passed visual check.


## Final integration checkpoint

The final Library header shares one row with the fixed page/help controls; the expanded player reserves that row before its own playback header. The release build and package checks passed. Final consolidated-header/resize visual validation is awaiting manual Mac unlock, and is not marked passed.
