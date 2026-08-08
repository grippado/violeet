#!/usr/bin/env bash
#
# Turn a screen recording into the three files the demo needs.
#
#   scripts/make-demo.sh ~/Desktop/raw.mov --start 2.4 --duration 14 \
#       --crop 2880:1620:0:180
#
# Writes docs/demo.mp4, docs/demo.webm and docs/demo.gif from one take.
# The video pair is what the project page plays; the GIF exists because a
# README on GitHub cannot play anything else, and it is the expensive one.
#
# Nothing here is destructive: it reads the recording and writes into docs/.
set -euo pipefail

SOURCE=""
START=""
DURATION=""
CROP=""
WIDTH=960
FPS=12
OUT_DIR=""

usage() {
  cat <<'USAGE'
usage: make-demo.sh <recording.mov> [options]

  --start <seconds>     skip this much from the front (accepts 2.4)
  --duration <seconds>  how much to keep after --start
  --crop <w:h:x:y>      crop, in the recording's own pixels
  --width <px>          width of the output; height follows (default 960)
  --fps <n>             frames per second (default 12)
  --out <dir>           where to write (default docs/ beside this script)

The defaults aim at a README: 960px at 12fps reads fine for UI motion and
keeps the GIF in single-digit megabytes. Raise them for the video pair by
running twice if you want the page sharper than the README.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --start)    START="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --crop)     CROP="$2"; shift 2 ;;
    --width)    WIDTH="$2"; shift 2 ;;
    --fps)      FPS="$2"; shift 2 ;;
    --out)      OUT_DIR="$2"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    -*)         echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)          SOURCE="$1"; shift ;;
  esac
done

if [ -z "$SOURCE" ]; then
  echo "no recording given" >&2
  usage >&2
  exit 2
fi
if [ ! -f "$SOURCE" ]; then
  echo "no such file: $SOURCE" >&2
  exit 1
fi
if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ffmpeg is not installed: brew install ffmpeg" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/docs}"
mkdir -p "$OUT_DIR"

# Seeking before -i is the fast kind and lands on a keyframe, which is what we
# want: this is a screen recording, so every frame is close to a keyframe and
# the imprecision costs nothing.
TRIM=()
[ -n "$START" ] && TRIM+=(-ss "$START")
[ -n "$DURATION" ] && TRIM+=(-t "$DURATION")

# `-2` rather than `-1` on the height: H.264 in yuv420p needs both dimensions
# even, and an odd height is the error you only see after the encode.
CHAIN=""
[ -n "$CROP" ] && CHAIN="crop=$CROP,"
CHAIN="${CHAIN}scale=$WIDTH:-2:flags=lanczos"

say() { printf '\n\033[35m%s\033[0m\n' "$1"; }
weigh() {
  # Same number the browser will download, in the unit a person thinks in.
  du -h "$1" | cut -f1 | tr -d ' '
}

say "→ $OUT_DIR/demo.mp4"
ffmpeg -hide_banner -loglevel error -y "${TRIM[@]}" -i "$SOURCE" \
  -vf "$CHAIN" \
  -c:v libx264 -profile:v high -crf 21 -preset slow \
  -pix_fmt yuv420p -movflags +faststart -an \
  "$OUT_DIR/demo.mp4"

say "→ $OUT_DIR/demo.webm"
ffmpeg -hide_banner -loglevel error -y "${TRIM[@]}" -i "$SOURCE" \
  -vf "$CHAIN" \
  -c:v libvpx-vp9 -crf 34 -b:v 0 -row-mt 1 -an \
  "$OUT_DIR/demo.webm"

# The GIF goes through its own palette, twice.
#
# A GIF holds 256 colours, and the one ffmpeg picks by default is a generic
# ramp that turns a violet UI into bands. `stats_mode=diff` weighs the palette
# towards the pixels that actually move, which is right here: most of this
# frame is a background that never changes and does not deserve a vote.
#
# Bayer dithering rather than the prettier error-diffusion kinds: those scatter
# noise that differs frame to frame, and a GIF pays for every changed pixel. On
# flat UI colour Bayer is both smaller and cleaner.
say "→ $OUT_DIR/demo.gif"
PALETTE="$(mktemp -t violeet-palette).png"
trap 'rm -f "$PALETTE"' EXIT

ffmpeg -hide_banner -loglevel error -y "${TRIM[@]}" -i "$SOURCE" \
  -vf "$CHAIN,fps=$FPS,palettegen=stats_mode=diff" "$PALETTE"

ffmpeg -hide_banner -loglevel error -y "${TRIM[@]}" -i "$SOURCE" -i "$PALETTE" \
  -lavfi "$CHAIN,fps=${FPS}[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" \
  "$OUT_DIR/demo.gif"

say "done"
for file in demo.mp4 demo.webm demo.gif; do
  printf '  %-11s %s\n' "$file" "$(weigh "$OUT_DIR/$file")"
done

# A README that takes a beat to paint is a README with a heavy GIF in it. This
# is the number to act on, and the two levers are --width and --fps.
GIF_KB=$(du -k "$OUT_DIR/demo.gif" | cut -f1)
if [ "$GIF_KB" -gt 5120 ]; then
  printf '\n  the GIF is over 5 MB. Try --width 800, or --fps 10, or a shorter --duration.\n'
fi
