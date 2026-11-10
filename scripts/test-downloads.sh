#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/savetube-download-checks.XXXXXX")"
SERVER_PID=""
cleanup() { if [[ -n "$SERVER_PID" ]]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi; rm -rf "$SCRATCH"; }
trap cleanup EXIT
APP="$SCRATCH/DownloadChecks.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$SCRATCH/media"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>DownloadChecks</string><key>CFBundleIdentifier</key><string>local.savetube.downloadchecks</string></dict></plist>
PLIST
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
swiftc -swift-version 5 -sdk "$SDK" -parse-as-library "$ROOT/Sources/SaveTube/DownloadEngine.swift" "$ROOT/Tests/DownloadChecks/main.swift" -o "$APP/Contents/MacOS/DownloadChecks"
if [[ "${1:-}" == "--real" ]]; then
    HELPERS="${2:-$ROOT/dist/SaveTube.app/Contents/Helpers}"
    for tool in yt-dlp ffmpeg ffprobe; do
        [[ -x "$HELPERS/$tool" ]] || { echo "Missing $HELPERS/$tool; build the app first." >&2; exit 1; }
        ln -s "$HELPERS/$tool" "$APP/Contents/Helpers/$tool"
    done
    # Fixture generation may use the developer FFmpeg, while conversion uses release helpers.
    "${FFMPEG_FIXTURE:-ffmpeg}" -hide_banner -loglevel error -f lavfi -i testsrc=size=160x90:rate=10 -f lavfi -i sine=frequency=440:sample_rate=44100 -t 1 -c:v libx264 -pix_fmt yuv420p -c:a aac "$SCRATCH/media/fixture.mp4"
    python3 - "$SCRATCH/media" "$SCRATCH/port" <<'PY' &
import functools, http.server, sys
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[1]))
with open(sys.argv[2], 'w') as stream:
    stream.write(str(server.server_port))
server.serve_forever()
PY
    SERVER_PID=$!
    for attempt in {1..50}; do [[ -s "$SCRATCH/port" ]] && break; sleep 0.1; done
    PORT="$(cat "$SCRATCH/port")"
    "$APP/Contents/MacOS/DownloadChecks" "$SCRATCH/output" "http://127.0.0.1:$PORT/fixture.mp4" --real
    for kind in MP4 MP3; do
        find "$SCRATCH/output/$kind" -iname "*.$kind" -exec "$HELPERS/ffprobe" -v error -show_entries stream=codec_name -of default=noprint_wrappers=1 {} \;
    done
else
    cat > "$APP/Contents/Helpers/yt-dlp" <<'MOCK'
#!/bin/sh
output=''
kind=mp4
previous=''
for argument in "$@"; do
    if [ "$previous" = '--output' ]; then output="$argument"; fi
    if [ "$previous" = '--audio-format' ]; then kind="$argument"; fi
    previous="$argument"
done
case "$previous" in
    *cancel*) sleep 30; exit 0;;
    *failure*) echo 'ERROR: Test extractor failure' >&2; exit 1;;
esac
file="$(printf '%s' "$output" | sed "s/%(title)s/DownloadChecks/;s/%(id)s/mock/;s/%(ext)s/$kind/")"
printf 'SAVETUBE_PROGRESS: 30.0%%|2MiB/s|00:01\n'
printf 'test media' > "$file"
printf 'SAVETUBE_PROGRESS:100.0%%|2MiB/s|00:00\n'
printf 'SAVETUBE_FILE:%s\n' "$file"
MOCK
    printf '#!/bin/sh\nexit 0\n' > "$APP/Contents/Helpers/ffmpeg"
    chmod +x "$APP/Contents/Helpers/"*
    "$APP/Contents/MacOS/DownloadChecks" "$SCRATCH/output" "https://example.invalid/video"
fi
