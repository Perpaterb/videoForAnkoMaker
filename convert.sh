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

PROFILE="amv"
PROFILE_EXPLICIT=0
SIZE="160x128"
FIT="crop"
ROTATE="0"
FPS="15"
JOBS="1"
TRIM_BARS="auto"
EXT_OVERRIDE=""
AUDIO="profile"
AUDIO_RATE=""
QUALITY=""
FORCE=0
DRY_RUN=0
TEST_CLIPS=0
CLIP_SECONDS=20

VALID_PROFILES="amv mjpeg xvid mpeg4 h264"

usage() {
  cat <<'USAGE'
Usage: ./convert.sh [options]

Converts every video in videosToConvert/ into converted/, as .amv or .avi
depending on the profile.

Options:
  --test-clips        Build short test clips into testclips/ instead of
                      converting the whole batch: every profile crossed with
                      every orientation. Copy them to the player to find out
                      what it accepts. Pass --profile as well to build just
                      that one profile.
  --profile NAME      Codec profile. Default: amv
                        amv     AMV video + IMA ADPCM audio, .amv container.
                                What these players were built for. Try first.
                        mjpeg   MJPEG video + PCM audio, .avi  (big files)
                        xvid    Xvid video + MP3 audio, .avi   (needs a real Xvid decoder)
                        mpeg4   MPEG-4 SP video + MP3 audio, .avi
                        h264    H.264 baseline + AAC, .mp4. For players built
                                on Spreadtrum chipsets, which take MP4 rather
                                than AVI.

                      AMV constraints, enforced below: output height must be a
                      multiple of 16, audio is always 22050 Hz mono, and --fps
                      must divide 22050 exactly (5 6 7 9 10 14 15 18 21 25 30).
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
  --ext EXT           Force the output file extension, without changing what is
                      actually encoded. Some players filter their file browser
                      by extension: this Anko unit lists .avi and does not show
                      .amv at all, so "--profile amv --ext avi" writes AMV data
                      into a file the browser will display.
  --audio MODE        Override the profile's audio. Cheap decoders are fussy
                      here, and mono is a common reason a file is rejected.
                        profile     whatever the profile specifies (default)
                        pcm-stereo  PCM 16-bit, 22050 Hz, stereo
                        pcm-mono    PCM 16-bit, 22050 Hz, mono
                        mp3-stereo  MP3 64k, 44100 Hz, stereo
                        mp3-mono    MP3 64k, 22050 Hz, mono
                        aac         AAC 160k
                        none        no audio track at all
  --audio-rate N      Override the audio sample rate. Halving it halves the size
                      of a PCM track, which dominates the output on long files.
                      Test on the player before committing a whole batch to it.
  --quality N         Encoder -q:v value, 1 is best. Profile default otherwise.
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
  ./convert.sh --profile amv --size 128x160 --rotate 90

  # Landscape file. Fills the screen only if the player auto-rotates.
  ./convert.sh --profile amv --size 160x128

  ./convert.sh --profile xvid --jobs 4    # smaller files, four at a time
  ./convert.sh --size 128x160 --fit pad   # upright, whole frame, black bars
USAGE
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --test-clips)     TEST_CLIPS=1; shift ;;
    --profile)        PROFILE="${2:-}"; PROFILE_EXPLICIT=1; shift 2 ;;
    --size)           SIZE="${2:-}"; shift 2 ;;
    --fit)            FIT="${2:-}"; shift 2 ;;
    --rotate)         ROTATE="${2:-}"; shift 2 ;;
    --fps)            FPS="${2:-}"; shift 2 ;;
    --trim-bars)      TRIM_BARS="${2:-}"; shift 2 ;;
    --ext)            EXT_OVERRIDE="${2:-}"; shift 2 ;;
    --audio)          AUDIO="${2:-}"; shift 2 ;;
    --audio-rate)     AUDIO_RATE="${2:-}"; shift 2 ;;
    --quality)        QUALITY="${2:-}"; shift 2 ;;
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

# AMV is far pickier than AVI. Check the combination up front and say exactly
# what is wrong, rather than letting ffmpeg fail with "could not write header".
validate_amv() {
  local h="$1" fps="$2"
  if (( h % 16 != 0 )); then
    die "AMV needs a height that is a multiple of 16, but --size gives ${h}.
       Try 128x160 (the native screen) or 160x128."
  fi
  if (( 22050 % fps != 0 )); then
    die "AMV locks audio to 22050 Hz and needs --fps to divide it exactly.
       ${fps} does not. Valid: 5 6 7 9 10 14 15 18 21 25 30 (15 is the default)."
  fi
}

if [[ -n "$EXT_OVERRIDE" ]]; then
  EXT_OVERRIDE="${EXT_OVERRIDE#.}"
  [[ "$EXT_OVERRIDE" =~ ^[A-Za-z0-9]{1,8}$ ]] \
    || die "Bad --ext '$EXT_OVERRIDE'. Expected a short alphanumeric extension, e.g. avi"
fi

case "$AUDIO" in
  profile|pcm-stereo|pcm-mono|mp3-stereo|mp3-mono|aac|none) ;;
  *) die "Bad --audio '$AUDIO'. Valid: profile pcm-stereo pcm-mono mp3-stereo mp3-mono aac none" ;;
esac

if [[ -n "$AUDIO_RATE" ]]; then
  [[ "$AUDIO_RATE" =~ ^[0-9]+$ && "$AUDIO_RATE" -ge 8000 ]] \
    || die "Bad --audio-rate '$AUDIO_RATE'. Expected a sample rate in Hz, e.g. 11025"
fi

if [[ -n "$QUALITY" ]]; then
  [[ "$QUALITY" =~ ^[0-9]+$ && "$QUALITY" -ge 1 && "$QUALITY" -le 31 ]] \
    || die "Bad --quality '$QUALITY'. Expected 1-31, where 1 is best."
fi

# AMV's audio is part of the container contract, not a free choice.
if [[ "$PROFILE" == "amv" && "$AUDIO" != "profile" ]]; then
  die "--profile amv fixes its own audio (IMA ADPCM, 22050 Hz mono) because the
       muxer ties the audio frame size to the frame rate. Drop --audio."
fi

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

# --test-clips picks its own geometries, so it validates per clip instead.
if [[ "$PROFILE" == "amv" && $TEST_CLIPS -eq 0 ]]; then
  validate_amv "$HEIGHT" "$FPS"
fi

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
# Sets PROFILE_ARGS (codec flags), PROFILE_FORMAT (muxer) and PROFILE_EXT.
# Wraps set_profile_args so --ext applies everywhere the extension is used.
set_profile() {
  set_profile_args "$1"
  [[ -n "$EXT_OVERRIDE" ]] && PROFILE_EXT="$EXT_OVERRIDE"
  return 0
}

set_profile_args() {
  case "$1" in
    amv)
      # What Actions-chipset players take. Three hard constraints, enforced by
      # validate_amv(): audio is 22050 Hz mono, the muxer demands exactly
      # sample_rate/fps samples per audio frame (that is -block_size, and the
      # header will not write without it), and height must be a multiple of 16.
      PROFILE_VARGS=( -c:v amv -pix_fmt yuvj420p -q:v "${QUALITY:-6}" )
      PROFILE_AARGS=( -c:a adpcm_ima_amv -ar 22050 -ac 1 -block_size $((22050 / FPS)) )
      PROFILE_FORMAT="amv"; PROFILE_EXT="amv"
      ;;
    mjpeg)
      # Every frame is a standalone JPEG, which is what the cheapest decoder
      # chips manage. Stereo PCM at 22050 matches the settings known to work on
      # Shenju-based 128x160 players; mono is a common cause of rejection.
      PROFILE_VARGS=( -c:v mjpeg -pix_fmt yuvj420p -q:v "${QUALITY:-2}" )
      PROFILE_AARGS=( -c:a pcm_s16le -ar 22050 -ac 2 )
      PROFILE_FORMAT="avi"; PROFILE_EXT="avi"
      ;;
    xvid)
      PROFILE_VARGS=( -c:v libxvid -pix_fmt yuv420p -vtag XVID -q:v "${QUALITY:-6}" )
      PROFILE_AARGS=( -c:a libmp3lame -b:a 64k -ar 44100 -ac 2 )
      PROFILE_FORMAT="avi"; PROFILE_EXT="avi"
      ;;
    mpeg4)
      # ffmpeg's built-in MPEG-4 encoder, tagged DIVX because some players
      # dispatch on the FourCC rather than sniffing the stream.
      PROFILE_VARGS=( -c:v mpeg4 -pix_fmt yuv420p -vtag DIVX -q:v "${QUALITY:-6}" )
      PROFILE_AARGS=( -c:a libmp3lame -b:a 64k -ar 44100 -ac 2 )
      PROFILE_FORMAT="avi"; PROFILE_EXT="avi"
      ;;
    h264)
      # Spreadtrum-based 128x160 players take MP4 rather than AVI. Baseline
      # level 1 is the ceiling these decoders handle.
      PROFILE_VARGS=( -c:v libx264 -profile:v baseline -level 1 -pix_fmt yuv420p )
      PROFILE_AARGS=( -c:a aac -b:a 160k )
      PROFILE_FORMAT="mp4"; PROFILE_EXT="mp4"
      ;;
  esac

  # --audio overrides whatever the profile chose.
  case "$AUDIO" in
    profile)    ;;
    pcm-stereo) PROFILE_AARGS=( -c:a pcm_s16le -ar 22050 -ac 2 ) ;;
    pcm-mono)   PROFILE_AARGS=( -c:a pcm_s16le -ar 22050 -ac 1 ) ;;
    mp3-stereo) PROFILE_AARGS=( -c:a libmp3lame -b:a 64k -ar 44100 -ac 2 ) ;;
    mp3-mono)   PROFILE_AARGS=( -c:a libmp3lame -b:a 64k -ar 22050 -ac 1 ) ;;
    aac)        PROFILE_AARGS=( -c:a aac -b:a 160k ) ;;
    none)       PROFILE_AARGS=( -an ) ;;
  esac

  # Rewrite -ar in whatever the audio args ended up being.
  if [[ -n "$AUDIO_RATE" && "$AUDIO" != "none" ]]; then
    local out=() i=0
    while (( i < ${#PROFILE_AARGS[@]} )); do
      if [[ "${PROFILE_AARGS[$i]}" == "-ar" ]]; then
        out+=( -ar "$AUDIO_RATE" ); i=$((i + 2))
      else
        out+=( "${PROFILE_AARGS[$i]}" ); i=$((i + 1))
      fi
    done
    PROFILE_AARGS=( "${out[@]}" )
  fi

  PROFILE_ARGS=( "${PROFILE_VARGS[@]}" "${PROFILE_AARGS[@]}" )
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
              -f "$PROFILE_FORMAT" "$dst" )
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

  # Build every profile by default. If --profile was named explicitly, build
  # only that one, so a second round of testing does not rebuild formats the
  # player has already rejected.
  local profiles="$VALID_PROFILES"
  if [[ $PROFILE_EXPLICIT -eq 1 ]]; then
    profiles="$PROFILE"
    note "Only building the '$PROFILE' profile (--profile was given)."
    note ""
  fi

  local made=0 failed=0
  local prof v name w h rot out
  for prof in $profiles; do
    set_profile "$prof"
    for v in "${variants[@]}"; do
      read -r name w h rot <<<"$v"
      if [[ "$prof" == "amv" ]] && (( h % 16 != 0 || 22050 % FPS != 0 )); then
        printf '  %-30s skipped (AMV cannot do %sx%s at %sfps)\n' "test_${prof}_${name}" "$w" "$h" "$FPS"
        continue
      fi
      out="$TEST_DIR/test_${prof}_${name}.${PROFILE_EXT}"
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
  note "Copy testclips/ onto the player."
  note ""
  if [[ $PROFILE_EXPLICIT -eq 0 ]]; then
    note "  1. WHICH PROFILE PLAYS AT ALL   $profiles"
    note "     A black screen with working audio means the video codec is not"
    note "     supported. \"Format not supported\" usually means the container is."
    note ""
    note "  2. WHICH ORIENTATION FILLS THE SCREEN"
  else
    note "  WHICH ORIENTATION FILLS THE SCREEN"
  fi
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
  note "  ./convert.sh --profile $PROFILE --size 128x160 --rotate 90   # sideways"
  note "  ./convert.sh --profile $PROFILE --size 160x128               # landscape"
  note "  ./convert.sh --profile $PROFILE --size 128x160               # upright"

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

  set_profile "$PROFILE"

  if [[ -n "$EXT_OVERRIDE" ]]; then
    note "Profile:  $PROFILE  (${PROFILE_FORMAT} data written as .${PROFILE_EXT})"
  else
    note "Profile:  $PROFILE  (.${PROFILE_EXT})"
  fi
  note "Size:     ${WIDTH}x${HEIGHT}  (fit: $FIT, rotate: ${ROTATE}deg, ${FPS}fps)"
  note "Input:    $IN_DIR  (${#files[@]} file(s))"
  note "Output:   $OUT_DIR"
  note "Log:      ${log#$ROOT/}"
  note ""

  # Global, not local: the EXIT trap fires after run_batch has returned, and a
  # local would be out of scope by then ("status_dir: unbound variable").
  STATUS_DIR="$(mktemp -d)"
  trap 'rm -rf "${STATUS_DIR:-}"' EXIT
  local status_dir="$STATUS_DIR"

  local total=${#files[@]} idx=0
  for f in "${files[@]}"; do
    idx=$((idx + 1))
    local base out
    base="$(basename "$f")"
    out="$OUT_DIR/${base%.*}.${PROFILE_EXT}"

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
    out_bytes="$(find "$OUT_DIR" -maxdepth 1 -type f \( -name '*.avi' -o -name '*.amv' \) -printf '%s\n' 2>/dev/null | awk '{t+=$1} END{print t+0}')"
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
