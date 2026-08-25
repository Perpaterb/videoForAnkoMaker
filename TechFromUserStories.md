# Technical log

One entry per story ID: what was actually built, and the files touched.

---

## US-001 — Batch convert a folder of videos

`run_batch()` in `convert.sh`. Collects input with
`find -maxdepth 1 -type f -print0 | sort -z` into a bash array, so filenames with
spaces and apostrophes survive intact (the real input set contains
`everyone's got a bottom.mp4`). Output name is the input basename with the
extension replaced by `.avi`.

Per-file results are written as single-word status files into a `mktemp -d`
directory rather than shell variables, because with `--jobs > 1` the conversions
run in subshells and variable increments would be lost. The tallies are read back
after `wait`.

Skip logic keys on `-s "$out"` (exists and non-empty), so a truncated output from
an interrupted run is retried rather than mistaken for a finished file.

Files: `convert.sh`

## US-002 — Correct geometry for the Anko screen

`build_vf()` in `convert.sh` builds the ffmpeg filter chain.

Rotation is emitted first (`transpose`), so `--fit` operates on the final
orientation rather than the source one. Then:

- `crop`: `scale=W:H:force_original_aspect_ratio=increase,crop=W:H` — scales until
  both axes cover the target, then centre-crops the overflow. This is what loses
  the left and right of a 16:9 source.
- `pad`: `force_original_aspect_ratio=decrease` plus a centred `pad`.
- `stretch`: a bare `scale=W:H`.

Every chain ends `,setsar=1`. Without it the AVI carries a non-square sample
aspect ratio and players that honour it draw the frame at the wrong shape.

Default size is `160x128`, landscape. `--size` is parsed with a `^([0-9]+)x([0-9]+)$`
regex, so a malformed value is caught before ffmpeg is invoked.

Files: `convert.sh`

## US-003 — Find a codec the player actually accepts

`set_profile_args()` and `run_test_clips()` in `convert.sh`.

Three profiles:

- `mjpeg` — `-c:v mjpeg -q:v 6 -pix_fmt yuvj420p` with `-c:a pcm_s16le -ar 22050 -ac 1`.
  Every frame is a standalone JPEG, which is what the cheapest decoder chips cope
  with. Audio is mono 22 kHz specifically because uncompressed stereo 44.1 kHz PCM
  is ~10 MB/min and would dwarf the video on a long read-aloud.
- `xvid` — `-c:v libxvid -vtag XVID` with `-c:a libmp3lame -b:a 64k`.
- `mpeg4` — ffmpeg's built-in `mpeg4` encoder, `-vtag DIVX`. The explicit FourCC
  tags matter: some players dispatch on the tag rather than sniffing the stream.

`--test-clips` renders 3 profiles x 2 geometries = 6 clips from the first input
file that `ffprobe` confirms has a video stream. It seeks 15 s in when the source
is long enough, so the clip is real content rather than a title card.

The device-confirmation criterion is intentionally left unchecked in
`UserStories.md`. Nothing on this machine can prove which format the player
accepts.

Files: `convert.sh`

## US-004 — Visible progress and an honest report

Progress lines are `printf` with a `%-52.52s` field so long book titles are
truncated to a fixed column and the results stay aligned. ffmpeg's own output is
appended to `logs/convert-<timestamp>.log`, never the terminal.

`--jobs N` gates on `while [[ $(jobs -rp | wc -l) -ge $JOBS ]]; do wait -n; done`.

`human_size()` formats byte counts via `awk`.

Files: `convert.sh`

## US-005 — Fails clearly instead of mysteriously

`require_tools()` checks `ffmpeg` and `ffprobe` up front and prints the apt
command. All flag validation happens before any work starts. `has_video_stream()`
uses `ffprobe -select_streams v:0` so a stray `.txt` or cover image in the input
folder is skipped rather than counted as a failure.

Files: `convert.sh`

## US-006 — Remove black bars already baked into the source

`detect_bars()` in `convert.sh`, wired in by `convert_one()` which prepends the
result to the filter chain ahead of rotation and fitting.

Found by extracting a frame from `3 little pigs 1.mp4` and looking at it: the
"16:9" sources are mostly a squarish page image on a black background.
`cropdetect` across the folder confirmed 45 of 53 files carry ~160px bars each
side (1280x720 with content at 962x720+156).

Detection runs `cropdetect=24:2:0` over 90 frames at 20%, 50% and 80% of
duration, and takes the **union** of the proposed rectangles rather than trusting
one. A dark scene makes `cropdetect` propose a window tighter than the real
picture; unioning means the failure mode is leaving a sliver of bar on rather
than slicing into the page. Sampling across the folder showed the detected
rectangle is stable to within 2px per file, so the union costs nothing in
practice while removing the tail risk.

Two guards: any sample that would discard more than 70% of an axis is ignored,
and the final rectangle is rounded outward to even offsets and dimensions
because yuv420p cannot represent odd chroma geometry.

Cost is three short decode passes per file, a few seconds each.

Files: `convert.sh`

## US-007 — AMV output

`set_profile_args()` gained an `amv` case and now sets three things rather than
one: `PROFILE_ARGS`, `PROFILE_FORMAT` (the muxer) and `PROFILE_EXT`. Output
filenames in `run_batch()` use `PROFILE_EXT`, and `convert_one()` passes
`-f "$PROFILE_FORMAT"`, so a profile is free to change container.

Getting AMV to encode at all took three findings, none of them documented in
ffmpeg's help output:

1. `adpcm_ima_amv` only opens at **22050 Hz**. 16000, 24000 and 8000 all fail at
   encoder-open.
2. The AMV muxer demands exactly `sample_rate / fps` samples per audio frame.
   The encoder defaults to 1024, so the header refuses to write with
   "Invalid audio frame size. Got 1024, wanted 1378". The fix is the encoder's
   `-block_size`, computed as `22050 / FPS`.
3. Consequently **fps must divide 22050 exactly**: 5 6 7 9 10 14 15 18 21 25 30.
   15 is the default and needs no change.
4. The encoder rejects a **height that is not a multiple of 16**. 128x160 and
   160x128 are both fine; 160x120 is not.

`validate_amv()` checks 1, 3 and 4 before any work starts and names the actual
rule in the error, because ffmpeg's own failure ("Could not write header
(incorrect codec parameters ?)") says nothing useful.

Files: `convert.sh`

## US-008 — Extension override and a diagnostic probe pack

`--ext` is applied by `set_profile()`, a thin wrapper around
`set_profile_args()` that overrides `PROFILE_EXT` after the profile has set its
own default. Everything downstream already used `PROFILE_EXT`, so nothing else
needed to change, and `PROFILE_FORMAT` is untouched: the muxer still writes AMV,
only the filename differs.

The device evidence that motivated this: nine AVI clips were listed and rejected
with "Video Format Not Supported", then three AMV clips produced "no videos
detected". Listing is the discriminator. The browser filters on extension, so
the `.amv` files were never examined at all and their rejection says nothing
about whether AMV would play.

`scripts/probe-pack.sh` builds nine clips that vary one property at a time
across two live hypotheses: that AMV is correct but was misnamed (variants 1-4),
and that AVI was correct all along but the resolution was wrong (variants 6-9).
Variant 5 is the control, AMV under its own extension, which should stay
invisible if the extension theory holds.

It decodes the source once into a short excerpt and re-encodes that for each
variant, rather than seeking into the full file nine times. Labels are
digit-prefixed and under 16 characters so they sort predictably and stay
readable truncated on a 128x160 screen.

Files: `scripts/probe-pack.sh`, `convert.sh`

## US-009 — Match settings known to work on other 128x160 players

The Anko manual gives "AVI (128 x 160 resolution; conversion required)", which
confirms the container and geometry were correct in round one and moves the
problem inside the file.

`set_profile_args()` was split: it now sets `PROFILE_VARGS` and `PROFILE_AARGS`
separately and concatenates them into `PROFILE_ARGS`, so `--audio` can replace
the audio half without the profiles each having to know about the flag.

Settings published as working on other 128x160 units differ from the original
attempt in three ways, all now the `mjpeg` profile's defaults: **stereo** PCM
rather than mono, 16 fps, and `-q:v 2`. Mono is the strongest suspect, since
these decoders commonly assume two channels.

Verified by encoding the same source through `convert.sh` and through the
reference command directly, then comparing with `ffprobe`: codec, dimensions,
pixel format, frame rate, audio codec, sample rate and channel count all match.

`--audio none` also drops `-map 0:a:0?`, because mapping a stream and then
passing `-an` is contradictory.

A guard rejects `--audio` on `--profile amv`: that muxer ties the audio frame
size to the frame rate via `-block_size`, so the audio is part of the container
contract rather than a free choice.

Files: `convert.sh`, `scripts/probe-pack.sh`

### Bug fixed: stderr noise on every successful batch

`run_batch()` declared `status_dir` with `local` and then registered
`trap 'rm -rf "$status_dir"' EXIT`. The trap fires after the function has
returned, so the variable was out of scope and every successful run ended with
`status_dir: unbound variable` on stderr under `set -u`. Now stored in a global
`STATUS_DIR`. A test asserts a clean run writes nothing to stderr at all.

## Testing

`scripts/smoke.sh` builds a synthetic 640x360 source with `lavfi` (`testsrc` plus
`sine`), named `it's a test clip.mp4` to exercise the quoting path, and then
invokes `./convert.sh` as a subprocess. It does not source the script or call its
functions: production's door is the CLI, so the tests use the CLI. Assertions read
back real values with `ffprobe` (`format_name`, `stream=width/height/codec_name`,
`format=duration`).

`--verify-fails` runs a correct conversion and then asserts deliberately wrong
dimensions (999x999). It exits 0 only when the assertions actually failed, which
is what makes the rest of the suite meaningful.

Two assertions check pixels rather than metadata, because a frame-size check
cannot distinguish a real transpose from a resize:

- Rotation: a source that is red on the left and blue on the right must come out
  red on top after `--rotate 90`. This catches a rotation that is missing, or
  applied anticlockwise.
- Bar trimming: a 360x360 red/blue image centred on a 640x360 black background
  must come out red at the left edge with `--trim-bars auto`, and must *not* with
  `--trim-bars off`. The negative half is what stops the flag silently becoming a
  no-op.

Both read back average colours with `ffmpeg -f rawvideo -pix_fmt rgb24` piped
through `od`.

A regression test covers `-i` and `-o` pointing at the same folder: the batch
used to pick up its own `.avi` output as a source on the next run and hand ffmpeg
the same path to read and write. `run_batch()` now compares `readlink -f` of both
paths and skips.

AMV needed two assertions rewritten rather than reused, because the format
genuinely differs from AVI:

- **Container.** AMV is a RIFF container derived from AVI, so `ffprobe` reports
  `format_name=avi` for both. The distinguishing feature is the `AMV ` signature
  at byte 8, so the test reads the bytes with `dd`. The `.avi` branch asserts the
  inverse, that the signature is absent, so the two cannot silently swap.
- **Duration.** AMV headers carry no duration field; `ffprobe` returns `N/A` by
  design. Asserting `duration > 0` would have been asserting something false
  about the format, so the AMV branch counts decoded video packets with
  `-count_packets` instead, which is the property actually worth checking.

A further test encodes AMV at 10 fps, not just the default 15, so a `-block_size`
accidentally hardcoded to 1470 would fail.

`--target <dir>` points the same assertions at an existing folder of `.avi` or
`.amv` files, including an SD card mount. It takes the geometry and codec of the first file as
the reference and requires every other file to match, since a player that accepts
one size may reject another.

Files: `scripts/smoke.sh`
