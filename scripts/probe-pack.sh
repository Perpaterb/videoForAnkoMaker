#!/usr/bin/env bash
#
# Build a labelled diagnostic pack for a player that has rejected everything so
# far. Each clip varies ONE thing, and its filename says what, so whatever plays
# on the device tells you which variable mattered.
#
# The naming is the point: you read these on a tiny screen, so the label has to
# survive being truncated.
#
#   ./scripts/probe-pack.sh                      # the "recipes" pack (default)
#   ./scripts/probe-pack.sh --pack containers    # container/extension/resolution
#   ./scripts/probe-pack.sh --seconds 10
#   ./scripts/probe-pack.sh --source "videosToConvert/Stuck.mp4"

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONVERT="$ROOT/convert.sh"
OUT="$ROOT/testclips"
SECONDS_LEN=15
SOURCE=""
PACK="recipes"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pack)    PACK="${2:-}"; shift 2 ;;
    --source)  SOURCE="${2:-}"; shift 2 ;;
    --seconds) SECONDS_LEN="${2:-}"; shift 2 ;;
    --out)     OUT="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# Built from settings published as working on other 128x160 players, with one
# variable changed per clip so a result identifies a cause rather than just a
# winner. The Anko manual specifies "AVI (128 x 160 resolution)", so AVI at that
# size is the baseline and the clips vary what sits inside it.
#
# label          profile ext  size     rot fps audio       qual  what it isolates
RECIPES=(
  "1shenju_side  mjpeg   avi  128x160  90  16  pcm-stereo  2   known-good AVI recipe, rotated"
  "2shenju_land  mjpeg   avi  160x128   0  16  pcm-stereo  2   same recipe, landscape"
  "3mono_side    mjpeg   avi  128x160  90  16  pcm-mono    2   is MONO audio the problem?"
  "4noaud_side   mjpeg   avi  128x160  90  16  none        2   is audio the problem at all?"
  "5mp3_side     mjpeg   avi  128x160  90  16  mp3-stereo  2   MP3 instead of PCM"
  "6h264_land    h264    mp4  160x128   0  14  aac         0   Spreadtrum recipe, MP4"
  "7h264_side    h264    mp4  128x160  90  14  aac         0   same, rotated"
  "8xvid_side    xvid    avi  128x160  90  16  pcm-stereo  6   Xvid with the good audio"
  "9fps25_side   mjpeg   avi  128x160  90  25  pcm-stereo  2   is the FRAME RATE the problem?"
)

# label          profile ext  size     rot fps audio       qual  what it isolates
CONTAINERS=(
  "1amv_avi_side amv     avi  128x160  90  15  profile     6   AMV data, .avi name"
  "2amv_avi_land amv     avi  160x128   0  15  profile     6   AMV data, .avi name, landscape"
  "3amv_avi_208  amv     avi  208x176   0  15  profile     6   AMV data, classic size"
  "4amv_avi_320  amv     avi  320x240   0  15  profile     6   AMV data, large classic size"
  "5amv_amv_208  amv     amv  208x176   0  15  profile     6   control: .amv name"
  "6mjpg_160x120 mjpeg   avi  160x120   0  15  pcm-stereo  2   AVI at classic 160x120"
  "7mjpg_320x240 mjpeg   avi  320x240   0  15  pcm-stereo  2   AVI at 320x240"
  "8mjpg_208x176 mjpeg   avi  208x176   0  15  pcm-stereo  2   AVI at 208x176"
  "9mp4v_320x240 mpeg4   avi  320x240   0  15  mp3-stereo  6   MPEG-4 AVI at 320x240"
)

case "$PACK" in
  recipes)    VARIANTS=( "${RECIPES[@]}" ) ;;
  containers) VARIANTS=( "${CONTAINERS[@]}" ) ;;
  *) printf 'Unknown --pack "%s". Valid: recipes, containers\n' "$PACK" >&2; exit 2 ;;
esac

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

printf 'Pack:   %s\n' "$PACK"
printf 'Source: %s\n' "$(basename "$SOURCE")"
printf 'Building a %ss excerpt...\n\n' "$SECONDS_LEN"
ffmpeg -hide_banner -nostdin -y -ss 25 -t "$SECONDS_LEN" -i "$SOURCE" \
  -c:v libx264 -pix_fmt yuv420p -c:a aac "$STAGE/excerpt.mp4" >/dev/null 2>&1 \
  || { printf 'Could not build the excerpt.\n' >&2; exit 2; }

made=0; failed=0
printf '%-16s %-6s %-8s %-4s %-11s %s\n' "FILE" "CODEC" "SIZE" "FPS" "AUDIO" "ISOLATES"
printf '%s\n' "---------------------------------------------------------------------------"

for v in "${VARIANTS[@]}"; do
  read -r label profile ext size rot fps audio qual rest <<<"$v"
  in="$STAGE/in_$label"; mkdir -p "$in"
  cp "$STAGE/excerpt.mp4" "$in/$label.mp4"

  args=( -i "$in" -o "$OUT" --force --profile "$profile" --ext "$ext"
         --size "$size" --rotate "$rot" --fps "$fps" )
  [[ "$audio" != "profile" ]] && args+=( --audio "$audio" )
  [[ "$qual" != "0" ]]        && args+=( --quality "$qual" )

  if "$CONVERT" "${args[@]}" >"$STAGE/log_$label" 2>&1; then
    printf '%-16s %-6s %-8s %-4s %-11s %s\n' "$label.$ext" "$profile" "$size" "$fps" "$audio" "$rest"
    made=$((made + 1))
  else
    printf '%-16s FAILED  %s\n' "$label.$ext" \
      "$(grep -iE 'error|invalid|cannot|needs|bad ' "$STAGE/log_$label" | head -1 | cut -c1-50)"
    failed=$((failed + 1))
  fi
  rm -rf "$in"
done

printf '\n%d built, %d failed. In %s/\n\n' "$made" "$failed" "${OUT#$ROOT/}"

if [[ "$PACK" == "recipes" ]]; then
cat <<'GUIDE'
Copy them all across. The leading digit keeps them ordered on screen.

Two separate things to note for each: whether it is LISTED, and whether it PLAYS.

  1 or 2 plays    The recipe is right. That is the one to use for all 53.
  3 fails but 1 plays    Mono audio was the problem all along.
  4 plays, 1 does not    The audio track is the problem, not the video.
  5 plays         It wants MP3 rather than PCM.
  6 or 7 plays    It is a Spreadtrum-type player and wants MP4, not AVI.
  9 plays         The frame rate was the problem.

  The .mp4 files are not LISTED at all
      The browser filters those out too, same as it did .amv, and MP4 is ruled
      out regardless of what is inside them.

Tell me which filenames were listed and which played, and I will convert all 53.
GUIDE
fi
