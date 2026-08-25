# User Stories: Anko MP5 video converter

Converts a folder of videos into AVI files an Anko MP5 player (128x160 screen) accepts.

Status key: `[x]` done and verified, `[~]` partial, `[ ]` not done.

---

## US-001 — Batch convert a folder of videos

As Bob, I drop videos in `videosToConvert/` and run one command to get player-ready
AVIs in `converted/`.

- [x] `./convert.sh` with no arguments processes every video file in `videosToConvert/`
- [x] Output written to `converted/` with the same base name and `.avi` extension
- [x] Spaces and apostrophes in filenames are handled
- [x] Already-converted files are skipped unless `--force` is passed
- [x] A failed file does not stop the batch; it is logged and the run continues
- [x] Exit code is non-zero if any file failed

## US-002 — Correct geometry for the Anko screen

As Bob, output frames fill the 128x160 screen with no black bars, cropping the sides.

- [x] Default output is 160x128 (landscape, watched sideways)
- [x] `--size 128x160` produces portrait output instead
- [x] `--fit crop` (default) centre-crops to fill; `--fit pad` letterboxes; `--fit stretch` distorts to fill
- [x] `--rotate 90` bakes a rotation in, for the case where the player refuses to display landscape files
- [x] Verified by `ffprobe`: output stream dimensions exactly match the requested size
- [x] Verified at pixel level: `--rotate 90` genuinely turns the picture clockwise,
      not merely reshapes the frame

## Working configuration (confirmed on the device)

```
./convert.sh --profile mjpeg --size 128x160 --rotate 90 \
             --audio pcm-stereo --quality 2 --fps 16
```

Watched with the player held sideways.

---

## US-003 — Find a codec the player actually accepts

As Bob, I can test which format my player plays before committing 53 files to it.

- [x] `./convert.sh --test-clips` produces one short clip per codec profile into `testclips/`
- [x] Profiles: `mjpeg` (MJPEG + PCM), `xvid` (Xvid + MP3), `mpeg4` (MPEG-4 SP + MP3)
- [x] Each clip is named for its profile so you know which one worked
- [x] `--profile <name>` selects the profile for the full batch; default `amv`
- [x] Test clips cover all three orientation strategies (sideways / landscape / upright),
      so one round of testing answers codec and orientation together
- [x] **Tested on the device**: all nine AVI clips were listed by the player but
      every one reported "Video Format Not Supported". Codec-independent and
      geometry-independent, so the AVI container itself is rejected. See US-007.
- [ ] **A format that plays on the device has been found**

  Still open. AMV clips are built and waiting to be tried.

## US-004 — Visible progress and an honest report

As Bob, I can see what is happening across a 2.3 GB, 53-file batch and what failed.

- [x] Per-file progress line: index, name, and result
- [x] Full ffmpeg output goes to a log file, not the terminal
- [x] Summary at the end: converted, skipped, failed, total output size
- [x] `--dry-run` prints the ffmpeg command for each file without running it
- [x] `--jobs N` converts N files concurrently

## US-005 — Fails clearly instead of mysteriously

- [x] Missing `ffmpeg` produces a clear message with the install command, not a bare "command not found"
- [x] Missing/empty input folder is reported plainly
- [x] A source file that is not a video is skipped with a note, not treated as a failure
- [x] Invalid `--profile`, `--size`, `--fit`, `--rotate`, `--trim-bars`, `--jobs`, `--fps` values are rejected with a usable message
- [x] Pointing `-o` at the input folder does not make the batch convert its own output onto itself

## US-006 — Remove black bars already baked into the source

Added after inspecting real frames: 45 of the 53 input files are a 962x720 picture
pillarboxed inside a 1280x720 frame. Cropping those to fit the screen discarded
real picture while the black bars survived onto the display.

- [x] `--trim-bars auto` (default) detects the border and removes it before fitting
- [x] Detection samples three points in the file and takes the union, so one dark
      scene cannot cause an over-crop
- [x] Detection refuses any proposal that would discard more than 70% of either axis
- [x] Crop dimensions and offsets are rounded to even numbers for yuv420p
- [x] `--trim-bars off` disables it for a file that comes out wrong
- [x] Verified at pixel level: a synthetic pillarboxed source runs edge-to-edge
      picture with `auto`, and still shows bar with `off`

## US-007 — AMV output

The device rejected all three AVI profiles across all three geometries, which
rules out the container rather than any codec. This class of player is built
around AMV, which is why they historically shipped with a bundled converter.

- [x] `--profile amv` produces a `.amv` file: AMV video plus IMA ADPCM audio
- [x] `amv` is the default profile, since AVI is now known not to work here
- [x] Output extension follows the profile, so `converted/` gets `.amv` not `.avi`
- [x] AMV's constraints are enforced up front with messages naming the real rule:
      height a multiple of 16, and `--fps` must divide 22050 exactly
- [x] `-block_size` is computed as 22050/fps rather than hardcoded, verified by a
      test at a non-default frame rate
- [x] `--test-clips --profile amv` builds only that profile, so a second round of
      testing does not rebuild formats already ruled out
- [x] **Tested on the device**: the player reported "no videos detected". It did
      not list the `.amv` files at all, where it *had* listed the `.avi` files.
      The file browser filters by extension. See US-008.
- [ ] **Confirmed playing on the device**

## US-008 — Extension override and a diagnostic probe pack

The player lists `.avi` and does not show `.amv`, so its browser filters by
extension. What is inside the file and what the file is called have to be
separable.

- [x] `--ext EXT` forces the output extension without changing the encoding
- [x] `--profile amv --ext avi` writes real AMV data (verified by the `AMV `
      signature at byte 8) into a file named `.avi`
- [x] No stray file under the profile's own extension is left behind
- [x] Bad `--ext` values are rejected
- [x] `scripts/probe-pack.sh` builds a labelled 9-clip diagnostic set that varies
      one thing at a time: container, extension and resolution
- [x] Clip names are short and digit-prefixed so they stay readable and ordered
      on a 128x160 screen
- [x] **Tested on the device**: 8 of 9 listed, and #5 (the `.amv`) was the one
      missing, exactly as the control predicted. The extension filter is real.
      All 8 listed clips still reported "Video Format Not Supported", ruling out
      both AMV-in-`.avi` and the resolution theory. See US-009.

## US-009 — Match settings known to work on other 128x160 players

The Anko manual specifies "AVI (128 x 160 resolution; conversion required)", so
the container and geometry were right from the start and the problem is inside
the file. Published settings for other 128x160 players differ from the first
attempt in three ways: stereo rather than mono audio, 16 fps, and `-q:v 2`.

- [x] `--audio MODE` overrides the profile's audio: `pcm-stereo`, `pcm-mono`,
      `mp3-stereo`, `mp3-mono`, `aac`, `none`
- [x] `--quality N` sets the encoder `-q:v`
- [x] New `h264` profile writes H.264 baseline level 1 + AAC into `.mp4`, for
      Spreadtrum-based players
- [x] The `mjpeg` profile now defaults to stereo PCM at `-q:v 2`, matching the
      settings published as working elsewhere
- [x] `--profile amv` refuses an `--audio` override rather than silently ignoring
      it, since the AMV muxer ties audio frame size to frame rate
- [x] Verified: output stream properties match the reference command exactly
      (codec, size, pixel format, frame rate, audio codec, rate, channels)
- [x] `probe-pack.sh --pack recipes` builds a 9-clip set isolating one variable
      each: stereo vs mono, audio vs none, PCM vs MP3, AVI vs MP4, frame rate
- [x] **CONFIRMED ON THE DEVICE.** Clips 1 and 9 play. The working format is:

      MJPEG video, 128x160, `-q:v 2`, with **PCM stereo 22050 Hz** audio.

      The failures pin down each requirement rather than leaving it assumed:
      - #3 mono, #4 no audio, #5 MP3 all failed -> stereo PCM is required
      - #8 Xvid and #6/#7 H.264/MP4 failed -> MJPEG only
      - #2 at 160x128 failed -> exactly 128x160, as the manual states
      - #1 at 16fps and #9 at 25fps both worked -> frame rate is flexible

## US-010 — Keep the output within the card

The confirmed settings produce 6.06 GB across the 53 files (9 hours of content),
of which 2.66 GB is PCM audio that cannot be compressed while staying in the
format the player accepts.

- [x] `--audio-rate N` overrides the sample rate; halving it halves the PCM track
- [x] Verified the flag actually shrinks the file, not just changes the metadata
- [x] Measured, not estimated, on a real 60s sample from the collection:
      - `-q:v 2`, 22050 Hz -> 6.06 GB  (the proven configuration)
      - `-q:v 6`, 22050 Hz -> 4.34 GB
      - `-q:v 2`, 11025 Hz -> 4.73 GB
      - `-q:v 6`, 11025 Hz -> 3.01 GB
- [ ] **A reduced-size variant confirmed playing on the device**

  `-q:v` only changes JPEG quantisation, so it is very unlikely to affect
  acceptance. Changing the sample rate is a real change to a working
  configuration and should be tested before a whole batch depends on it.

---

## Testing

- [x] `./scripts/smoke.sh` builds a synthetic source and drives `convert.sh` from the
      outside, asserting geometry, codec and duration with `ffprobe`
- [x] `./scripts/smoke.sh --verify-fails` proves the assertions go red against wrong output
- [x] `./scripts/smoke.sh --target <dir>` validates AVIs already in a folder, including
      an SD card mount, and checks they all agree on geometry and codec
- [x] 128 assertions passing, 0 failing, as of the last run
