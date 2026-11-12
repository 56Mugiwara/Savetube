# MediaFetch polish report

Maintenance pass: 12 November 2026. Scope is the existing Downloader, Library and
player experience. No major features, rebranding or broad redesign are included.
The baseline is v1.2.0 (`a35889c`). This report separates source changes, fixture
checks and observations of the packaged app.

## Interaction consistency

Glass controls now define their hit shape inside the button label after applying
its material. A global enlarged rectangular hit area previously overrode circular
and capsule shapes; it has been removed. Circular actions use circular targets,
text buttons use capsules, and the four actions within the shared toolbar use
separate 44-point rectangular cells. This preserves the full bubble target without
letting invisible corners overlap neighboring controls. Downloader Settings now
uses the same 44-point circle as the shared header controls.

The selection lens continues to render separately from its labels, preserving
stationary text during dragging. Hold expansion and bounded edge stretch remain.
The player collapse control retains a 44-point visual circle and a larger 52-point
circular target. Existing Reduce Motion behavior is preserved.

Validation: source inspection and production build passed. Packaged blank-padding
clicks opened Help and switched workspaces. The Move sheet opened and canceled
without moving a file. Space paused and resumed playback, and a two-word search
survived switching pages while playback advanced beyond 38 seconds.

## Navigation and window layout

Both workspaces remain mounted to preserve link text, filters, selection and scroll
state. Hidden pages gate input and periodic work. The common page switch and Help
stay in one root overlay; the Library's header reserves their space and compensates
for the native split-view top inset. Compact layouts retain sidebar, search and an
Actions menu. The window retains its immersive transparent titlebar. The sidebar keeps native
List selection and keyboard navigation while using quieter icons, theme-colour
emphasis on the selected destination, compact counts and smaller section headings.
Opening/closing the sidebar uses a single 0.22-second ease-in/out transition.
The overlapping explicit/implicit springs reported as glitchy were removed.
Reduce Motion disables the transition. With the sidebar hidden, the left toolbar
reserves space for the traffic lights.

Validation: v1.2.0 packaged checks verified header alignment and compact Actions.
Exact minimum-size, fullscreen and maintenance-build checks are listed in the
verification section; they are not inferred from source alone.

## Playback and visual feedback

Pausing now updates macOS Now Playing state and playback rate immediately; seeking
publishes its new elapsed time. Focused checks cover rapid next/previous, preparing
pause/resume, queue completion, repeat-one restart and unavailable queue entries.
The small seek and spectrum views observe the clock independently of large page
views, so normal playback does not redraw the whole library four times per second.

The v1.2.0 spectrum fix is retained: partial analysis becomes available before the
whole song finishes, and the display follows the animation timeline. FFT scratch
arrays and frequency-bin ranges are now reused. A failed request invalidates the
previous generation so a canceled reader cannot replace the current error later.

The player retains its artwork-colour lava-lamp fields. No new visual effect was
added in this maintenance pass. Hue-preserving palette extraction, distinct colour
roles and neutral grayscale fallback remain covered by the palette checks.

## File-operation flow

Both Move File entry points now use a shared asynchronous destination sheet instead
of a nested modal run loop. Existing-history import also uses a sheet. Canceling a
picker leaves files alone; the selected file's current location is resolved by the
library before moving it.

Pending imports now follow virtual-folder renames. If the destination folder is
deleted during copying, the imported media remains in the library without
recreating that deleted folder. Regression checks cover both paths and preserve
the original source files.

Background-copy errors are surfaced through a concise app alert. Repeated errors
are deduplicated by media type and category; helper output retains at most a
1024-byte partial line. Unexpected exits are reported, while intentional shutdown
removes handlers and closes pipes without an erroneous stopped-helper alert.

## Performance evidence

A controlled 300-second generated MP3 was analyzed twice with the baseline source
and twice with the maintenance source, using the same compiler, SDK and harness.
Baseline user CPU was 11.76/11.69 seconds; maintenance was 11.87/12.00 seconds.
Peak RSS was approximately 22.2–22.4 MB for all four runs. Both versions produced
identical sampled band output. These results show no measurable end-to-end CPU or
RSS improvement in this workload. Scratch-buffer reuse removes repeated
allocations in source, but is not presented as a measured whole-app RAM reduction.

Instruments/xctrace is unavailable in the installed Command Line Tools. The
benchmark does not measure UI frame pacing, tab-switch latency or GPU usage.

## Verification and remaining checks

Passed focused checks: library/file operations and queued imports; background
helper failure reporting, bounded diagnostics, restart and stop; playback/Now
Playing state; spectrum fixtures; vivid and neutral palette fixtures. Production
packaging and final UI observations will be recorded after the new build completes.

Packaged checks verified blank-area Help/page targets, Move-sheet cancellation,
Space pause/resume, search retention during playback, narrow/wide headers, and the
refined sidebar appearance and collapse/reopen states. The user then reported the
sidebar animation as glitchy. Its two overlapping springs have been replaced by
one eased transition, but the final motion has not been observed: the user asked
that the app remain closed, and it was not relaunched for this final change.

Still requiring explicit verification: exact 800×680 layout, final sidebar motion,
fullscreen transitions, VoiceOver navigation, external-volume moves and hardware
frame pacing. A source change is not treated as a passed UI check.

## Release gate

Ship a patch release after the production build, signature and ZIP checks pass and
any reproducible blocking UI regression found during the final pass is fixed.
Keep v1.2.0 available for rollback. Further work stays limited to defects and polish;
the earlier feature roadmap is deferred.
