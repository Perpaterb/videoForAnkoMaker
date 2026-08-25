#!/usr/bin/env bash
#
# Build a labelled diagnostic pack for a player that has rejected everything so
# far. Each clip varies ONE thing, and its filename says what, so whatever plays
# on the device tells you which variable mattered.
#
# The naming is the point: you are reading these on a tiny screen, so the label
# has to survive being truncated to the first few characters.
#
#   ./scripts/probe-pack.sh                  # default source, 15s clips
#   ./scripts/probe-pack.sh --seconds 10
#   ./scripts/probe-pack.sh --source "videosToConvert/Stuck.mp4"

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONVERT="$ROOT/convert.sh"
OUT="$ROOT/testclips"
SECONDS_LEN=15
SOURCE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)  SOURCE="${2:-}"; shift 2 ;;
    --seconds) SECONDS_LEN="${2:-}"; shift 2 ;;
    --out)     OUT="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# label            profile  ext   size      rotate  what it tests
VARIANTS=(
  "1amv_avi_side   amv      avi   128x160   90    AMV data, .avi name, native screen size"
  "2amv_avi_land   amv      avi   160x128    0    AMV data, .avi name, landscape"
  "3amv_avi_208    amv      avi   208x176    0    AMV data, .avi name, classic AMV size"
  "4amv_avi_320    amv      avi   320x240    0    AMV data, .avi name, classic large size"
  "5amv_amv_208    amv      amv   208x176    0    AMV data, .amv name, classic size"
  "6mjpg_160x120   mjpeg    avi   160x120    0    MJPEG AVI at the classic 160x120"
  "7mjpg_320x240   mjpeg    avi   320x240    0    MJPEG AVI at 320x240"
  "8mjpg_208x176   mjpeg    avi   208x176    0    MJPEG AVI at 208x176"
  "9mp4v_320x240   mpeg4    avi   320x240    0    MPEG-4 AVI at 320x240"
)

if [[ -z "$SOURCE" ]]; then
  for f in "$ROOT"/videosToConvert/*; do
    [[ -f "$f" ]] || continue
    if ffprobe -v error -select_streams v:0 -show_entries stream=codec_type -of csv=p=0 "$f" 2>/dev/null | grep -q video; then
      SOURCE="$f"; break
    fi
  done
fi
[[ -n "$SOURCE" && -f "$SOURCE" ]] || { printf 'No source video found.\n' >&2; exit 2; }

mkdir -p "$OUT"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# One short clip, reused for every variant, so encoding time is spent on the
# variants rather than re-decoding the full source each time.
printf 'Source: %s\n' "$(basename "$SOURCE")"
printf 'Building a %ss excerpt...\n\n' "$SECONDS_LEN"
ffmpeg -hide_banner -nostdin -y -ss 25 -t "$SECONDS_LEN" -i "$SOURCE" \
  -c:v libx264 -pix_fmt yuv420p -c:a aac "$STAGE/excerpt.mp4" >/dev/null 2>&1 \
  || { printf 'Could not build the excerpt.\n' >&2; exit 2; }

made=0; failed=0
printf '%-16s %-7s %-5s %-9s %s\n' "FILE" "CODEC" "EXT" "SIZE" "RESULT"
printf '%s\n' "----------------------------------------------------------------"

for v in "${VARIANTS[@]}"; do
  read -r label profile ext size rotate _rest <<<"$v"
  in="$STAGE/in_$label"; mkdir -p "$in"
  cp "$STAGE/excerpt.mp4" "$in/$label.mp4"

  if "$CONVERT" -i "$in" -o "$OUT" --force \
       --profile "$profile" --ext "$ext" --size "$size" --rotate "$rotate" \
       >"$STAGE/log_$label" 2>&1; then
    printf '%-16s %-7s %-5s %-9s ok   %s\n' "$label.$ext" "$profile" "$ext" "$size" \
      "$(du -h "$OUT/$label.$ext" 2>/dev/null | cut -f1)"
    made=$((made + 1))
  else
    printf '%-16s %-7s %-5s %-9s FAILED  %s\n' "$label.$ext" "$profile" "$ext" "$size" \
      "$(grep -iE 'error|invalid|cannot|needs' "$STAGE/log_$label" | head -1 | cut -c1-40)"
    failed=$((failed + 1))
  fi
  rm -rf "$in"
done

printf '\n%d built, %d failed. In %s/\n\n' "$made" "$failed" "${OUT#$ROOT/}"
cat <<'GUIDE'
Copy them all to the player. The leading digit keeps them in order on screen.

What each answer would mean:

  Nothing is even LISTED except the .avi files
      The browser filters by extension. Already known; that is why most of
      these are named .avi regardless of what is inside.

  A 1-4 clip plays
      AMV is the right format and the .amv extension was the only problem.

  A 6-9 clip plays
      AVI is fine after all and the original nine failed on RESOLUTION.
      Whichever size works is the one to use for the whole batch.

  Everything still says "Format Not Supported"
      Neither container is right. Next suspects are MTV format, or a required
      folder on the card. Say so and we will go after those.

Tell me the filename that worked and I will convert all 53 to match.
GUIDE
