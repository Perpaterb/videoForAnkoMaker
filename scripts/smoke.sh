#!/usr/bin/env bash
#
# Smoke suite for the Anko video converter.
#
# Default mode builds a synthetic source clip, drives ./convert.sh exactly the
# way you would from the shell, and asserts with ffprobe that what came out is
# a real AVI of the exact expected geometry and codec.
#
# The tests enter through the same door as production: they shell out to
# convert.sh rather than sourcing its functions, so they cannot pass against a
# code path the script no longer uses.
#
#   ./scripts/smoke.sh                    # full synthetic end-to-end run
#   ./scripts/smoke.sh --target <dir>     # validate AVIs already in a folder
#                                         # (works on an SD card mount too)
#   ./scripts/smoke.sh --verify-fails     # prove the assertions can go red

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONVERT="$ROOT/convert.sh"

TARGET=""
VERIFY_FAILS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)       TARGET="${2:-}"; shift 2 ;;
    --verify-fails) VERIFY_FAILS=1; shift ;;
    -h|--help)      sed -n '2,14p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *)              printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

PASS=0
FAIL=0

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL + 1)); }

probe() { ffprobe -v error -select_streams "$1" -show_entries "$2" -of csv=p=0 "$3" 2>/dev/null; }

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$label = $actual"
  else
    fail "$label: expected '$expected', got '$actual'"
  fi
}

assert_gt0() {
  local label="$1" actual="$2"
  if [[ -n "$actual" ]] && awk "BEGIN{exit !($actual > 0)}"; then
    pass "$label = $actual"
  else
    fail "$label: expected > 0, got '$actual'"
  fi
}

# Asserts a whole AVI: container, geometry, video codec, audio presence, duration.
check_avi() {
  local file="$1" want_w="$2" want_h="$3" want_vcodec="$4" want_acodec="$5"

  printf '\n  -- %s\n' "$(basename "$file")"

  if [[ ! -s "$file" ]]; then
    fail "file exists and is non-empty"
    return
  fi
  pass "file exists and is non-empty"

  # AMV is a RIFF container derived from AVI, so ffprobe reports format_name
  # "avi" for both. The signature at byte 8 is what actually distinguishes
  # them, so check the bytes rather than trusting the format name.
  if [[ "$file" == *.amv ]]; then
    assert_eq "RIFF signature" "AMV " "$(dd if="$file" bs=1 skip=8 count=4 2>/dev/null)"
  else
    assert_eq "container" "avi" "$(ffprobe -v error -show_entries format=format_name -of csv=p=0 "$file" 2>/dev/null)"
    assert_eq "not an AMV in disguise" "" "$(dd if="$file" bs=1 skip=8 count=4 2>/dev/null | grep -o AMV)"
  fi
  assert_eq "width"       "$want_w"      "$(probe v:0 stream=width "$file")"
  assert_eq "height"      "$want_h"      "$(probe v:0 stream=height "$file")"
  [[ -n "$want_vcodec" ]] && assert_eq "video codec" "$want_vcodec" "$(probe v:0 stream=codec_name "$file")"
  [[ -n "$want_acodec" ]] && assert_eq "audio codec" "$want_acodec" "$(probe a:0 stream=codec_name "$file")"
  # AMV headers carry no duration field, so there is nothing to assert there.
  # Count decoded video packets instead, which is the thing we actually care
  # about: that the file contains playable frames.
  if [[ "$file" == *.amv ]]; then
    assert_gt0 "video packets" "$(ffprobe -v error -count_packets -select_streams v:0 -show_entries stream=nb_read_packets -of csv=p=0 "$file" 2>/dev/null)"
  else
    assert_gt0 "duration (s)" "$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$file" 2>/dev/null)"
  fi
}

# ------------------------------------------------------------ target mode

if [[ -n "$TARGET" ]]; then
  printf 'Validating AVIs in: %s\n' "$TARGET"
  [[ -d "$TARGET" ]] || { printf 'Not a directory: %s\n' "$TARGET" >&2; exit 2; }

  shopt -s nullglob
  files=( "$TARGET"/*.avi "$TARGET"/*.AVI "$TARGET"/*.amv "$TARGET"/*.AMV )
  shopt -u nullglob

  if [[ ${#files[@]} -eq 0 ]]; then
    printf '\nNo .avi or .amv files found in %s\n' "$TARGET" >&2
    exit 1
  fi

  # In target mode the expected geometry is whatever the first file has: the
  # point is that every file on the card agrees, since a player that accepts
  # one size may reject another.
  first_w="$(probe v:0 stream=width "${files[0]}")"
  first_h="$(probe v:0 stream=height "${files[0]}")"
  first_v="$(probe v:0 stream=codec_name "${files[0]}")"
  printf 'Reference (from first file): %sx%s %s\n' "$first_w" "$first_h" "$first_v"

  for f in "${files[@]}"; do
    check_avi "$f" "$first_w" "$first_h" "$first_v" ""
  done

  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  [[ $FAIL -eq 0 ]] || exit 1
  exit 0
fi

# ------------------------------------------------- synthetic end-to-end mode

command -v ffmpeg >/dev/null 2>&1 || {
  printf 'ffmpeg not found. Install it with: sudo apt install -y ffmpeg\n' >&2
  exit 2
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/in" "$WORK/out"

# A 16:9 source with audio, and an apostrophe and spaces in the name, because
# the real input folder has files like "everyone's got a bottom.mp4".
SRC="$WORK/in/it's a test clip.mp4"
printf 'Building synthetic source clip...\n'
ffmpeg -hide_banner -nostdin -y \
  -f lavfi -i "testsrc=size=640x360:rate=25:duration=5" \
  -f lavfi -i "sine=frequency=440:duration=5" \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest \
  "$SRC" >/dev/null 2>&1 || { printf 'Could not build the source clip.\n' >&2; exit 2; }

run_convert() {
  "$CONVERT" -i "$WORK/in" -o "$WORK/out" --force "$@" >"$WORK/log" 2>&1
}

# --verify-fails: deliberately break the mechanism and require a red result.
# A check that has never been seen to fail is not a check.
if [[ $VERIFY_FAILS -eq 1 ]]; then
  printf '\n=== --verify-fails: the suite must go RED below ===\n'
  run_convert --profile mjpeg --size 160x128 --fps 5
  # Assert the WRONG geometry on a correctly produced file.
  check_avi "$WORK/out/it's a test clip.avi" 999 999 "mjpeg" "pcm_s16le"
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  if [[ $FAIL -gt 0 ]]; then
    printf '\n\033[32mVERIFIED\033[0m: the assertions do fail when the output is wrong (%d failures above were expected).\n' "$FAIL"
    exit 0
  fi
  printf '\n\033[31mBROKEN\033[0m: the suite stayed green against deliberately wrong expectations.\n'
  exit 1
fi

printf '\n=== US-007: amv profile (the default) writes a real .amv ===\n'
if run_convert --profile amv --size 160x128 --fps 15; then
  pass "convert.sh --profile amv exited 0"
else
  fail "convert.sh --profile amv exited non-zero"; sed -n '1,40p' "$WORK/log" >&2
fi
check_avi "$WORK/out/it's a test clip.amv" 160 128 "amv" "adpcm_ima_amv"
amvfile="$WORK/out/it's a test clip.amv"
assert_eq "amv audio sample rate" "22050" "$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of csv=p=0 "$amvfile" 2>/dev/null)"
assert_eq "amv audio channels"    "1"     "$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 "$amvfile" 2>/dev/null)"

printf '\n=== US-007: amv at the native 128x160 screen size ===\n'
run_convert --profile amv --size 128x160 --rotate 90 --fps 15
check_avi "$WORK/out/it's a test clip.amv" 128 160 "amv" "adpcm_ima_amv"

printf '\n=== US-007: AMV constraints are rejected up front, not by ffmpeg ===\n'
# Height not a multiple of 16.
if "$CONVERT" -i "$WORK/in" -o "$WORK/out" --profile amv --size 160x120 --dry-run >"$WORK/logamv1" 2>&1; then
  fail "amv accepted a height of 120, which is not a multiple of 16"
else
  if grep -q "multiple of 16" "$WORK/logamv1"; then
    pass "amv rejected height 120 with a message naming the real constraint"
  else
    fail "amv rejected height 120 but the message did not explain why"
  fi
fi
# fps that does not divide 22050.
if "$CONVERT" -i "$WORK/in" -o "$WORK/out" --profile amv --fps 16 --dry-run >"$WORK/logamv2" 2>&1; then
  fail "amv accepted 16fps, which does not divide 22050"
else
  if grep -q "22050" "$WORK/logamv2"; then
    pass "amv rejected 16fps with a message naming the real constraint"
  else
    fail "amv rejected 16fps but the message did not explain why"
  fi
fi
# And a valid fps that is NOT the default must still work, so the block_size
# really is computed rather than hardcoded to 1470.
run_convert --profile amv --size 160x128 --fps 10
check_avi "$WORK/out/it's a test clip.amv" 160 128 "amv" "adpcm_ima_amv"

printf '\n=== US-002/US-003: default landscape geometry, mjpeg profile ===\n'
if run_convert --profile mjpeg --size 160x128 --fps 5; then
  pass "convert.sh exited 0"
else
  fail "convert.sh exited non-zero"; sed -n '1,40p' "$WORK/log" >&2
fi
check_avi "$WORK/out/it's a test clip.avi" 160 128 "mjpeg" "pcm_s16le"

printf '\n=== US-003: xvid profile ===\n'
if run_convert --profile xvid --size 160x128 --fps 5; then
  check_avi "$WORK/out/it's a test clip.avi" 160 128 "mpeg4" "mp3"
else
  fail "xvid profile failed (libxvid may not be compiled into this ffmpeg)"
  sed -n '1,40p' "$WORK/log" >&2
fi

printf '\n=== US-003: mpeg4 profile ===\n'
if run_convert --profile mpeg4 --size 160x128 --fps 5; then
  check_avi "$WORK/out/it's a test clip.avi" 160 128 "mpeg4" "mp3"
else
  fail "mpeg4 profile failed"; sed -n '1,40p' "$WORK/log" >&2
fi

printf '\n=== US-002: portrait geometry ===\n'
run_convert --profile mjpeg --size 128x160 --fps 5
check_avi "$WORK/out/it's a test clip.avi" 128 160 "mjpeg" "pcm_s16le"

printf '\n=== US-002: --rotate 90 still lands on the requested size ===\n'
run_convert --profile mjpeg --size 160x128 --fps 5 --rotate 90
check_avi "$WORK/out/it's a test clip.avi" 160 128 "mjpeg" "pcm_s16le"

printf '\n=== US-002: --rotate 90 rotates the pixels clockwise, not just the frame size ===\n'
# A frame size assertion cannot tell a real transpose from a plain resize, so
# this builds a source that is red on the LEFT and blue on the RIGHT. Rotated
# 90 degrees clockwise the left edge becomes the TOP, so a correct rotation
# gives red on top and blue underneath. A missing or backwards rotation is
# caught here and nowhere else.
mkdir -p "$WORK/rot" "$WORK/rotout"
ffmpeg -hide_banner -nostdin -y \
  -f lavfi -i "color=c=red:s=320x360:d=3[l];color=c=blue:s=320x360:d=3[r];[l][r]hstack" \
  -f lavfi -i "sine=frequency=440:duration=3" \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest \
  "$WORK/rot/leftred.mp4" >/dev/null 2>&1

# Average colour of the top half and the bottom half, as "R G B".
half_colour() {
  local file="$1" crop="$2"
  ffmpeg -hide_banner -nostdin -v error -i "$file" -frames:v 1 \
    -vf "${crop},scale=1:1" -f rawvideo -pix_fmt rgb24 - 2>/dev/null \
    | od -An -tu1 | tr -s ' ' | sed 's/^ //'
}
dominant() {
  # Returns "red", "blue" or "other" for an "R G B" triple.
  awk '{ if ($1 > 128 && $3 < 100) print "red";
         else if ($3 > 128 && $1 < 100) print "blue";
         else print "other" }' <<<"$1"
}

if "$CONVERT" -i "$WORK/rot" -o "$WORK/rotout" --force \
     --profile mjpeg --size 128x160 --fps 5 --fit stretch --rotate 90 \
     >"$WORK/logrot" 2>&1; then
  rotated="$WORK/rotout/leftred.avi"
  top="$(dominant "$(half_colour "$rotated" 'crop=iw:ih/2:0:0')")"
  bot="$(dominant "$(half_colour "$rotated" 'crop=iw:ih/2:0:ih/2')")"
  assert_eq "top half after --rotate 90 (was the left edge)"  "red"  "$top"
  assert_eq "bottom half after --rotate 90 (was the right edge)" "blue" "$bot"
else
  fail "--rotate 90 conversion failed"; sed -n '1,40p' "$WORK/logrot" >&2
fi

# And the same source with no rotation must stay left-red / right-blue.
if "$CONVERT" -i "$WORK/rot" -o "$WORK/rotout" --force \
     --profile mjpeg --size 160x128 --fps 5 --fit stretch \
     >"$WORK/logrot2" 2>&1; then
  flat="$WORK/rotout/leftred.avi"
  left="$(dominant "$(half_colour "$flat" 'crop=iw/2:ih:0:0')")"
  right="$(dominant "$(half_colour "$flat" 'crop=iw/2:ih:iw/2:0')")"
  assert_eq "left half without --rotate"  "red"  "$left"
  assert_eq "right half without --rotate" "blue" "$right"
else
  fail "unrotated control conversion failed"
fi

printf '\n=== US-002: --fit pad keeps the full frame ===\n'
run_convert --profile mjpeg --size 160x128 --fps 5 --fit pad
check_avi "$WORK/out/it's a test clip.avi" 160 128 "mjpeg" "pcm_s16le"

printf '\n=== US-001: already-converted files are skipped without --force ===\n'
"$CONVERT" -i "$WORK/in" -o "$WORK/out" --profile mjpeg --fps 5 >"$WORK/log2" 2>&1
if grep -q "skipped (already converted)" "$WORK/log2"; then
  pass "second run skipped the existing output"
else
  fail "second run did not skip: $(grep -c . "$WORK/log2") lines in log"
fi

printf '\n=== US-005: a non-video file is skipped, not counted as a failure ===\n'
printf 'not a video' > "$WORK/in/notes.txt"
if "$CONVERT" -i "$WORK/in" -o "$WORK/out" --profile mjpeg --fps 5 >"$WORK/log3" 2>&1; then
  pass "batch exited 0 with a junk file present"
else
  fail "batch exited non-zero because of a junk file"
fi
if grep -q "skipped (not a video)" "$WORK/log3"; then
  pass "junk file reported as skipped (not a video)"
else
  fail "junk file was not reported as skipped"
fi
rm -f "$WORK/in/notes.txt"

printf '\n=== US-004: --dry-run runs nothing and prints the command ===\n'
rm -f "$WORK/out"/*.avi
"$CONVERT" -i "$WORK/in" -o "$WORK/out" --dry-run --profile mjpeg >"$WORK/log4" 2>&1
if grep -q 'ffmpeg' "$WORK/log4"; then
  pass "--dry-run printed an ffmpeg command"
else
  fail "--dry-run printed no ffmpeg command"
fi
shopt -s nullglob; produced=( "$WORK/out"/*.avi ); shopt -u nullglob
if [[ ${#produced[@]} -eq 0 ]]; then
  pass "--dry-run produced no output files"
else
  fail "--dry-run produced ${#produced[@]} file(s)"
fi

printf '\n=== US-005: bad arguments are rejected ===\n'
for bad in "--profile nope" "--size 160-128" "--fit sideways" "--rotate 45" "--trim-bars maybe" "--jobs 0" "--fps x"; do
  # shellcheck disable=SC2086
  if "$CONVERT" -i "$WORK/in" -o "$WORK/out" $bad >/dev/null 2>&1; then
    fail "'$bad' was accepted"
  else
    pass "'$bad' was rejected"
  fi
done

printf '\n=== US-006: --trim-bars removes black baked into the source ===\n'
# Most of the real inputs are a squarish picture pillarboxed inside a 16:9
# frame. This builds that exact shape: a 360x360 image (red left, blue right)
# centred on a 640x360 black background. With --trim-bars auto the black is
# removed first, so the output runs red-to-blue edge to edge. With it off, the
# left edge of the output is still black bar.
mkdir -p "$WORK/bars" "$WORK/barsout"
ffmpeg -hide_banner -nostdin -y \
  -f lavfi -i "color=c=black:s=640x360:d=3[bg];color=c=red:s=180x360:d=3[l];color=c=blue:s=180x360:d=3[r];[l][r]hstack[img];[bg][img]overlay=(W-w)/2:0" \
  -f lavfi -i "sine=frequency=440:duration=3" \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest \
  "$WORK/bars/pillarboxed.mp4" >/dev/null 2>&1

if "$CONVERT" -i "$WORK/bars" -o "$WORK/barsout" --force \
     --profile mjpeg --size 160x128 --fps 5 --trim-bars auto \
     >"$WORK/logbars" 2>&1; then
  trimmed="$WORK/barsout/pillarboxed.avi"
  assert_eq "left edge with --trim-bars auto"  "red"  "$(dominant "$(half_colour "$trimmed" 'crop=iw/8:ih:0:0')")"
  assert_eq "right edge with --trim-bars auto" "blue" "$(dominant "$(half_colour "$trimmed" 'crop=iw/8:ih:iw*7/8:0')")"
else
  fail "--trim-bars auto conversion failed"; sed -n '1,40p' "$WORK/logbars" >&2
fi

if "$CONVERT" -i "$WORK/bars" -o "$WORK/barsout" --force \
     --profile mjpeg --size 160x128 --fps 5 --trim-bars off \
     >"$WORK/logbars2" 2>&1; then
  untrimmed="$WORK/barsout/pillarboxed.avi"
  edge="$(dominant "$(half_colour "$untrimmed" 'crop=iw/8:ih:0:0')")"
  if [[ "$edge" != "red" ]]; then
    pass "left edge with --trim-bars off is still bar, not picture ($edge)"
  else
    fail "--trim-bars off produced the same result as auto, so the flag does nothing"
  fi
else
  fail "--trim-bars off conversion failed"
fi

printf '\n=== US-005: output folder same as input folder does not eat its own output ===\n'
# Regression: the batch used to pick up the .avi it had just written as a new
# source on the next run, handing ffmpeg the same path to read and write.
mkdir -p "$WORK/same"
cp "$SRC" "$WORK/same/clip.mp4"
"$CONVERT" -i "$WORK/same" -o "$WORK/same" --profile mjpeg --fps 5 >/dev/null 2>&1
before="$(stat -c%s "$WORK/same/clip.avi" 2>/dev/null || echo 0)"
if "$CONVERT" -i "$WORK/same" -o "$WORK/same" --profile mjpeg --fps 5 >"$WORK/logsame" 2>&1; then
  pass "second in-place run exited 0"
else
  fail "second in-place run exited non-zero"
fi
after="$(stat -c%s "$WORK/same/clip.avi" 2>/dev/null || echo 0)"
assert_gt0 "output still intact after an in-place re-run" "$after"
assert_eq  "output unchanged by the in-place re-run" "$before" "$after"

printf '\n=== US-004: --jobs 2 converts every file ===\n'
cp "$SRC" "$WORK/in/second clip.mp4"
rm -f "$WORK/out"/*.avi
run_convert --profile mjpeg --size 160x128 --fps 5 --jobs 2
shopt -s nullglob; produced=( "$WORK/out"/*.avi ); shopt -u nullglob
assert_eq "files produced with --jobs 2" "2" "${#produced[@]}"

printf '\n----------------------------------------\n'
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
