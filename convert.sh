#!/usr/bin/env bash
#
# Convert a folder of videos into AVI files an Anko MP5 player will accept.
#
# The player has a 128x160 screen. Held sideways that is 160x128, which is the
# default output size here: the picture fills the screen with no black bars,
# at the cost of cropping the left and right off each frame.
#
# Which codec the player accepts cannot be determined from this machine.
# Run --test-clips first, copy them to the device, and see what plays.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IN_DIR="$ROOT/videosToConvert"
OUT_DIR="$ROOT/converted"
TEST_DIR="$ROOT/testclips"
LOG_DIR="$ROOT/logs"

PROFILE="mjpeg"
SIZE="160x128"
FIT="crop"
ROTATE="0"
FPS="15"
JOBS="1"
TRIM_BARS="auto"
FORCE=0
DRY_RUN=0
TEST_CLIPS=0
CLIP_SECONDS=20

VALID_PROFILES="mjpeg xvid mpeg4"

usage() {
  cat <<'USAGE'
Usage: ./convert.sh [options]

Converts every video in videosToConvert/ into converted/ as AVI.

Options:
  --test-clips        Build short test clips (one per profile, both geometries)
                      into testclips/ instead of converting the whole batch.
                      Copy these to the player to find out what it accepts.
  --profile NAME      Codec profile. Default: mjpeg
                        mjpeg   MJPEG video + PCM audio    (widest compatibility, big files)
                        xvid    Xvid video + MP3 audio     (small files, needs a real Xvid decoder)
                        mpeg4   MPEG-4 SP video + MP3 audio
  --size WxH          Output frame size. Default: 160x128 (landscape, held sideways).
                      Use 128x160 for portrait.
  --fit MODE          crop    centre-crop to fill, no bars, loses the sides (default)
                      pad     letterbox to fit, keeps the whole frame, adds black bars
                      stretch distort to fill
  --rotate DEG        Bake the rotation into the pixels: 0, 90, 180 or 270.
                      Default: 0. These players ignore rotation metadata, so
                      combine --size 128x160 --rotate 90 to fill the screen
                      with the player held sideways.
  --trim-bars MODE    auto  detect black bars already baked into the source and
                            remove them before fitting, so the crop eats black
                            rather than picture (default)
                      off   fit the source frame exactly as it is
  --fps N             Output frame rate. Default: 15
  --jobs N            Convert N files concurrently. Default: 1
  --clip-seconds N    Length of each test clip. Default: 20
  --force             Re-convert files that already exist in converted/
  --dry-run           Print the ffmpeg command for each file, run nothing
  -i, --input DIR     Input folder. Default: videosToConvert/
  -o, --output DIR    Output folder. Default: converted/
  -h, --help          This message

Examples:
  ./convert.sh --test-clips              # do this FIRST, then try them on the player

  # Full screen held sideways. Matches the 128x160 panel exactly and does not
  # rely on the player rotating anything, so it is the safest way to fill it.
  ./convert.sh --profile mjpeg --size 128x160 --rotate 90

  # Landscape file. Fills the screen only if the player auto-rotates.
  ./convert.sh --profile mjpeg --size 160x128

  ./convert.sh --profile xvid --jobs 4    # smaller files, four at a time
  ./convert.sh --size 128x160 --fit pad   # upright, whole frame, black bars
USAGE
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --test-clips)     TEST_CLIPS=1; shift ;;
    --profile)        PROFILE="${2:-}"; shift 2 ;;
    --size)           SIZE="${2:-}"; shift 2 ;;
    --fit)            FIT="${2:-}"; shift 2 ;;
    --rotate)         ROTATE="${2:-}"; shift 2 ;;
    --fps)            FPS="${2:-}"; shift 2 ;;
    --trim-bars)      TRIM_BARS="${2:-}"; shift 2 ;;
    --jobs)           JOBS="${2:-}"; shift 2 ;;
    --clip-seconds)   CLIP_SECONDS="${2:-}"; shift 2 ;;
    --force)          FORCE=1; shift ;;
    --dry-run)        DRY_RUN=1; shift ;;
    -i|--input)       IN_DIR="${2:-}"; shift 2 ;;
    -o|--output)      OUT_DIR="${2:-}"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *)                die "Unknown option: $1 (try --help)" ;;
  esac
done

# ---------------------------------------------------------------- validation

require_tools() {
  local missing=()
  command -v ffmpeg  >/dev/null 2>&1 || missing+=(ffmpeg)
  command -v ffprobe >/dev/null 2>&1 || missing+=(ffprobe)
  if [[ ${#missing[@]} -gt 0 ]]; then
    printf 'Error: %s not found on PATH.\n\n' "${missing[*]}" >&2
    printf 'Install it with:\n    sudo apt install -y ffmpeg\n' >&2
    exit 1
  fi
}

[[ " $VALID_PROFILES " == *" $PROFILE "* ]] \
  || die "Unknown profile '$PROFILE'. Valid: $VALID_PROFILES"

[[ "$SIZE" =~ ^([0-9]+)x([0-9]+)$ ]] \
  || die "Bad --size '$SIZE'. Expected WxH, e.g. 160x128"
WIDTH="${BASH_REMATCH[1]}"
HEIGHT="${BASH_REMATCH[2]}"

case "$FIT" in
  crop|pad|stretch) ;;
  *) die "Bad --fit '$FIT'. Valid: crop, pad, stretch" ;;
esac

case "$TRIM_BARS" in
  auto|off) ;;
  *) die "Bad --trim-bars '$TRIM_BARS'. Valid: auto, off" ;;
esac

case "$ROTATE" in
  0|90|180|270) ;;
  *) die "Bad --rotate '$ROTATE'. Valid: 0, 90, 180, 270" ;;
esac

[[ "$JOBS" =~ ^[0-9]+$ && "$JOBS" -ge 1 ]] || die "Bad --jobs '$JOBS'. Expected a positive integer"
[[ "$FPS" =~ ^[0-9]+$ && "$FPS" -ge 1 ]]   || die "Bad --fps '$FPS'. Expected a positive integer"

# ------------------------------------------------------------------ encoding

# Build the ffmpeg filter chain for a target geometry.
# Rotation is applied first so the fit operates on the final orientation.
# Many of these read-aloud recordings are a squarish picture pillarboxed inside
# a 16:9 frame, with black already baked down both sides. Fitting that frame as
# given means the crop throws away real picture while the black bars survive on
# to the player's screen. This samples a quarter of the way in and returns a
# crop filter for the actual content, or nothing if there is no clear border.
detect_bars() {
  local src="$1" sw sh dur
  sw="$(probe_v "$src" width)"; sh="$(probe_v "$src" height)"
  [[ -n "$sw" && -n "$sh" ]] || return 1

  dur="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$src" 2>/dev/null)"
  [[ -n "$dur" ]] || return 1

  # Sample three points and take the UNION of what they propose. A single dark
  # scene can make cropdetect suggest a window far tighter than the real
  # picture; widening to cover every sample means the worst case is leaving a
  # sliver of bar on, rather than slicing a chunk out of the page.
  local left=$sw top=$sh right=0 bottom=0 found=0
  local pct t crop rest cw ch cx cy

  for pct in 20 50 80; do
    t="$(awk "BEGIN{printf \"%d\", ($dur * $pct / 100)}")"
    crop="$(ffmpeg -hide_banner -nostdin -ss "$t" -i "$src" -frames:v 90 \
              -vf cropdetect=24:2:0 -f null - 2>&1 </dev/null \
            | grep -o 'crop=[0-9]*:[0-9]*:[0-9]*:[0-9]*' | tail -1)"
    [[ -n "$crop" ]] || continue

    rest="${crop#crop=}"
    cw="${rest%%:*}"; rest="${rest#*:}"
    ch="${rest%%:*}"; rest="${rest#*:}"
    cx="${rest%%:*}"; cy="${rest#*:}"

    # Ignore a sample that would discard more than 70% of either axis.
    awk "BEGIN{exit !($cw >= $sw * 0.3 && $ch >= $sh * 0.3)}" || continue

    (( cx < left ))        && left=$cx
    (( cy < top ))         && top=$cy
    (( cx + cw > right ))  && right=$((cx + cw))
    (( cy + ch > bottom )) && bottom=$((cy + ch))
    found=1
  done

  (( found )) || return 1

  local w=$((right - left)) h=$((bottom - top))

  # yuv420p needs even dimensions and offsets; round outward, then clamp.
  (( left % 2 ))  && left=$((left - 1))
  (( top % 2 ))   && top=$((top - 1))
  (( left < 0 ))  && left=0
  (( top < 0 ))   && top=0
  w=$((right - left)); h=$((bottom - top))
  (( w % 2 )) && w=$((w + 1))
  (( h % 2 )) && h=$((h + 1))
  (( left + w > sw )) && w=$((sw - left))
  (( top + h > sh ))  && h=$((sh - top))

  # Nothing worth removing.
  (( w >= sw && h >= sh )) && return 1

  printf 'crop=%d:%d:%d:%d' "$w" "$h" "$left" "$top"
}

build_vf() {
  local w="$1" h="$2" fit="$3" rot="$4" pre="${5:-}" chain=""
  [[ -n "$pre" ]] && chain="${pre},"
  case "$rot" in
    90)  chain+="transpose=1," ;;
    180) chain+="transpose=1,transpose=1," ;;
    270) chain+="transpose=2," ;;
  esac
  case "$fit" in
    crop)    chain+="scale=${w}:${h}:force_original_aspect_ratio=increase,crop=${w}:${h}" ;;
    pad)     chain+="scale=${w}:${h}:force_original_aspect_ratio=decrease,pad=${w}:${h}:(ow-iw)/2:(oh-ih)/2:color=black" ;;
    stretch) chain+="scale=${w}:${h}" ;;
  esac
  printf '%s,setsar=1' "$chain"
}

# Populates the PROFILE_ARGS array with codec flags for the named profile.
set_profile_args() {
  case "$1" in
    mjpeg)
      # MJPEG plus uncompressed PCM. Every frame is a standalone JPEG, which is
      # what the cheapest decoder chips cope with. Mono 22kHz keeps the
      # uncompressed audio from dwarfing the video.
      PROFILE_ARGS=( -c:v mjpeg -q:v 6 -pix_fmt yuvj420p
                     -c:a pcm_s16le -ar 22050 -ac 1 )
      ;;
    xvid)
      PROFILE_ARGS=( -c:v libxvid -q:v 6 -pix_fmt yuv420p -vtag XVID
                     -c:a libmp3lame -b:a 64k -ar 44100 -ac 2 )
      ;;
    mpeg4)
      # ffmpeg's built-in MPEG-4 encoder, tagged DIVX because some players
      # dispatch on the FourCC rather than sniffing the stream.
      PROFILE_ARGS=( -c:v mpeg4 -q:v 6 -pix_fmt yuv420p -vtag DIVX
                     -c:a libmp3lame -b:a 64k -ar 44100 -ac 2 )
      ;;
  esac
}

# convert_one <src> <dst> <w> <h> <fit> <rot> <logfile> [extra ffmpeg input args...]
convert_one() {
  local src="$1" dst="$2" w="$3" h="$4" fit="$5" rot="$6" log="$7"
  shift 7
  local pre=""
  if [[ "$TRIM_BARS" == "auto" ]]; then pre="$(detect_bars "$src")" || pre=""; fi
  local vf; vf="$(build_vf "$w" "$h" "$fit" "$rot" "$pre")"
  local cmd=( ffmpeg -hide_banner -nostdin -y "$@" -i "$src"
              -map 0:v:0 -map '0:a:0?'
              -vf "$vf" -r "$FPS"
              "${PROFILE_ARGS[@]}"
              -f avi "$dst" )
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '%q ' "${cmd[@]}"; printf '\n'
    return 0
  fi
  "${cmd[@]}" >>"$log" 2>&1
}

probe_v() {
  ffprobe -v error -select_streams v:0 -show_entries "stream=$2" -of csv=p=0 "$1" 2>/dev/null
}

has_video_stream() {
  local n
  n="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_type \
       -of csv=p=0 "$1" 2>/dev/null)"
  [[ "$n" == "video" ]]
}

human_size() {
  local bytes="$1"
  if   [[ "$bytes" -ge 1073741824 ]]; then awk "BEGIN{printf \"%.1f GB\", $bytes/1073741824}"
  elif [[ "$bytes" -ge 1048576 ]];    then awk "BEGIN{printf \"%.1f MB\", $bytes/1048576}"
  else awk "BEGIN{printf \"%.0f KB\", $bytes/1024}"
  fi
}

# --------------------------------------------------------------- test clips

run_test_clips() {
  require_tools
  mkdir -p "$TEST_DIR" "$LOG_DIR"
  local log="$LOG_DIR/testclips.log"; : > "$log"

  local src=""
  local f
  while IFS= read -r -d '' f; do
    if has_video_stream "$f"; then src="$f"; break; fi
  done < <(find "$IN_DIR" -maxdepth 1 -type f -print0 2>/dev/null | sort -z)

  [[ -n "$src" ]] || die "No video files found in $IN_DIR to build test clips from."

  note "Source clip:  $(basename "$src")"
  note "Building ${CLIP_SECONDS}s test clips into testclips/"
  note ""

  # Start a little way in, so the clip is real content rather than a title card.
  local start=15
  local dur; dur="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$src" 2>/dev/null)"
  if [[ -n "$dur" ]]; then
    awk "BEGIN{exit !($dur > $start + $CLIP_SECONDS)}" || start=0
  fi

  # Three orientation strategies, because it is not knowable from here which
  # one the player's firmware handles. See ORIENTATION_VARIANTS in the README.
  #   name       W    H    rotate
  local variants=(
    "sideways  128  160  90"
    "landscape 160  128   0"
    "upright   128  160   0"
  )

  local made=0 failed=0
  local prof v name w h rot out
  for prof in $VALID_PROFILES; do
    set_profile_args "$prof"
    for v in "${variants[@]}"; do
      read -r name w h rot <<<"$v"
      out="$TEST_DIR/test_${prof}_${name}.avi"
      printf '  %-30s ' "$(basename "$out")"
      if convert_one "$src" "$out" "$w" "$h" "$FIT" "$rot" "$log" \
           -ss "$start" -t "$CLIP_SECONDS"; then
        printf 'ok   (%s)\n' "$(human_size "$(stat -c%s "$out")")"
        made=$((made + 1))
      else
        printf 'FAILED (see %s)\n' "${log#$ROOT/}"
        rm -f "$out"
        failed=$((failed + 1))
      fi
    done
  done

  note ""
  note "Built $made clip(s), $failed failed."
  note ""
  note "Copy testclips/ onto the player. Two things to find out at once:"
  note ""
  note "  1. WHICH PROFILE PLAYS AT ALL   mjpeg / xvid / mpeg4"
  note "     Some will show nothing, or audio with a black screen."
  note ""
  note "  2. WHICH ORIENTATION FILLS THE SCREEN"
  note "     *_sideways   128x160 file, picture rotated into it."
  note "                  Turn the player SIDEWAYS. Should fill the screen."
  note "                  Best bet: matches the screen exactly, needs no"
  note "                  firmware rotation."
  note "     *_landscape  160x128 file. Only fills the screen if the player"
  note "                  auto-rotates. Otherwise expect a small upright"
  note "                  picture with bars above and below."
  note "     *_upright    128x160 file, watched normally. Fills the screen,"
  note "                  but crops the most off the sides of each page."
  note ""
  note "Then run the full batch with whatever won, e.g."
  note "  ./convert.sh --profile mjpeg --size 128x160 --rotate 90   # sideways"
  note "  ./convert.sh --profile mjpeg --size 160x128               # landscape"

  [[ $failed -eq 0 ]]
}

# -------------------------------------------------------------- batch runner

run_batch() {
  require_tools
  [[ -d "$IN_DIR" ]] || die "Input folder not found: $IN_DIR"
  mkdir -p "$OUT_DIR" "$LOG_DIR"

  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  local log="$LOG_DIR/convert-$stamp.log"; : > "$log"

  local files=()
  local f
  while IFS= read -r -d '' f; do files+=("$f"); done \
    < <(find "$IN_DIR" -maxdepth 1 -type f -print0 2>/dev/null | sort -z)

  [[ ${#files[@]} -gt 0 ]] || die "No files found in $IN_DIR"

  set_profile_args "$PROFILE"

  note "Profile:  $PROFILE"
  note "Size:     ${WIDTH}x${HEIGHT}  (fit: $FIT, rotate: ${ROTATE}deg, ${FPS}fps)"
  note "Input:    $IN_DIR  (${#files[@]} file(s))"
  note "Output:   $OUT_DIR"
  note "Log:      ${log#$ROOT/}"
  note ""

  local status_dir; status_dir="$(mktemp -d)"
  trap 'rm -rf "$status_dir"' EXIT

  local total=${#files[@]} idx=0
  for f in "${files[@]}"; do
    idx=$((idx + 1))
    local base out
    base="$(basename "$f")"
    out="$OUT_DIR/${base%.*}.avi"

    # Guard against -o pointing at the input folder: without this the batch
    # picks up its own .avi output on a later pass and asks ffmpeg to read and
    # write the same file, which corrupts it.
    if [[ "$(readlink -f "$f" 2>/dev/null)" == "$(readlink -f "$out" 2>/dev/null)" ]]; then
      printf '[%2d/%d] %-52.52s skipped (source and output are the same file)\n' "$idx" "$total" "$base"
      printf 'skipped' > "$status_dir/$idx"
      continue
    fi

    if [[ $FORCE -eq 0 && -s "$out" ]]; then
      printf '[%2d/%d] %-52.52s skipped (already converted)\n' "$idx" "$total" "$base"
      printf 'skipped' > "$status_dir/$idx"
      continue
    fi

    if ! has_video_stream "$f"; then
      printf '[%2d/%d] %-52.52s skipped (not a video)\n' "$idx" "$total" "$base"
      printf 'skipped' > "$status_dir/$idx"
      continue
    fi

    if [[ $JOBS -gt 1 ]]; then
      while [[ "$(jobs -rp | wc -l)" -ge "$JOBS" ]]; do wait -n 2>/dev/null || break; done
      (
        if convert_one "$f" "$out" "$WIDTH" "$HEIGHT" "$FIT" "$ROTATE" "$log"; then
          printf '[%2d/%d] %-52.52s ok      %s\n' "$idx" "$total" "$base" "$(human_size "$(stat -c%s "$out")")"
          printf 'ok' > "$status_dir/$idx"
        else
          printf '[%2d/%d] %-52.52s FAILED\n' "$idx" "$total" "$base"
          rm -f "$out"
          printf 'failed' > "$status_dir/$idx"
        fi
      ) &
    else
      printf '[%2d/%d] %-52.52s ' "$idx" "$total" "$base"
      if convert_one "$f" "$out" "$WIDTH" "$HEIGHT" "$FIT" "$ROTATE" "$log"; then
        if [[ $DRY_RUN -eq 1 ]]; then
          printf 'dry-run\n'
        else
          printf 'ok      %s\n' "$(human_size "$(stat -c%s "$out")")"
        fi
        printf 'ok' > "$status_dir/$idx"
      else
        printf 'FAILED\n'
        rm -f "$out"
        printf 'failed' > "$status_dir/$idx"
      fi
    fi
  done
  wait

  local ok=0 skipped=0 failed=0 s
  for s in "$status_dir"/*; do
    [[ -e "$s" ]] || continue
    case "$(cat "$s")" in
      ok)      ok=$((ok + 1)) ;;
      skipped) skipped=$((skipped + 1)) ;;
      failed)  failed=$((failed + 1)) ;;
    esac
  done

  local out_bytes=0
  if [[ $DRY_RUN -eq 0 && -d "$OUT_DIR" ]]; then
    out_bytes="$(find "$OUT_DIR" -maxdepth 1 -type f -name '*.avi' -printf '%s\n' 2>/dev/null | awk '{t+=$1} END{print t+0}')"
  fi

  note ""
  note "Converted: $ok    Skipped: $skipped    Failed: $failed"
  [[ $DRY_RUN -eq 0 ]] && note "Output total: $(human_size "$out_bytes")"
  if [[ $failed -gt 0 ]]; then
    note "Failures are detailed in ${log#$ROOT/}"
    return 1
  fi
  return 0
}

if [[ $TEST_CLIPS -eq 1 ]]; then
  run_test_clips
else
  run_batch
fi
