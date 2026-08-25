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

## US-003 — Find a codec the player actually accepts

As Bob, I can test which format my player plays before committing 53 files to it.

- [x] `./convert.sh --test-clips` produces one short clip per codec profile into `testclips/`
- [x] Profiles: `mjpeg` (MJPEG + PCM), `xvid` (Xvid + MP3), `mpeg4` (MPEG-4 SP + MP3)
- [x] Each clip is named for its profile so you know which one worked
- [x] `--profile <name>` selects the profile for the full batch; default `mjpeg`
- [x] Test clips cover all three orientation strategies (sideways / landscape / upright),
      so one round of testing answers codec and orientation together
- [ ] **Confirmed on the device**: one of the profiles plays on the actual Anko player

  Not verifiable from this machine. Requires copying `testclips/` to the player.
  Left unchecked deliberately until Bob reports which clip played.

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

---

## Testing

- [x] `./scripts/smoke.sh` builds a synthetic source and drives `convert.sh` from the
      outside, asserting geometry, codec and duration with `ffprobe`
- [x] `./scripts/smoke.sh --verify-fails` proves the assertions go red against wrong output
- [x] `./scripts/smoke.sh --target <dir>` validates AVIs already in a folder, including
      an SD card mount, and checks they all agree on geometry and codec
- [x] 66 assertions passing, 0 failing, as of the last run
