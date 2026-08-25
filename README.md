# Anko MP5 video converter

Turns a folder of videos into AVI files an Anko MP5 player will play, sized for
its 128x160 screen.

## Setup

```
sudo apt install -y ffmpeg
```

## Use it

**1. Find out what your player accepts.** Nothing on a PC can tell you this. The
only way to know is to put clips on the device.

```
./convert.sh --test-clips
```

That writes nine short clips to `testclips/`: three codec profiles crossed with
three orientation strategies. Copy the folder to the player and note which
filenames actually play, and which one fills the screen.

**2. Convert everything, using whatever won.**

```
./convert.sh --profile mjpeg --size 128x160 --rotate 90
```

Output lands in `converted/`. Re-running skips files that are already done, so
an interrupted batch resumes where it left off.

**3. Check the card before you trust it.**

```
./scripts/smoke.sh --target /media/bob/ANKO
```

Reads every AVI on the card and confirms they all agree on geometry and codec.

## Orientation

The screen is 128 wide by 160 tall. These players generally ignore rotation
metadata and most do not auto-rotate, so the orientation has to be baked into
the pixels. Three strategies, one per test clip:

| Clip | Produces | How you watch it | Notes |
|---|---|---|---|
| `*_sideways` | 128x160, picture rotated 90° clockwise inside it | Turn the player sideways | Matches the panel exactly and needs no firmware cooperation. Usually the winner. |
| `*_landscape` | 160x128 | Turn the player sideways | Only fills the screen if the firmware auto-rotates. Otherwise you get a small upright picture with bars. |
| `*_upright` | 128x160 | Hold it normally | Fills the screen, but crops the most off the sides of each page. |

The matching full-batch commands:

```
./convert.sh --size 128x160 --rotate 90     # sideways
./convert.sh --size 160x128                 # landscape
./convert.sh --size 128x160                 # upright
```

## Profiles

| Profile | Video | Audio | Size of a 5 min video | When |
|---|---|---|---|---|
| `mjpeg` | MJPEG | PCM 22 kHz mono | ~27 MB | Default. Every frame is a standalone JPEG, which is what the cheapest decoder chips manage. Try this first. |
| `xvid` | Xvid | MP3 64 kbps | ~4 MB | Much smaller. Needs a real Xvid decoder. |
| `mpeg4` | MPEG-4 SP | MP3 64 kbps | ~4 MB | Same size as xvid, different encoder and FourCC. Worth trying if `xvid` fails. |

If a profile plays but the picture is torn or the audio drifts, try the next one.
Black screen with working audio usually means the video codec is unsupported.

## Black bars

Most of these recordings are a squarish picture pillarboxed inside a 16:9 frame,
with black already baked down both sides. In this folder, 45 of 53 files are like
that: 1280x720 with the real picture only in the middle 962x720.

Cropping such a frame naively throws away real picture while the black bars
survive onto the screen. So `--trim-bars auto` (the default) detects the border
first and removes it, then fits what is left. Detection samples three points in
the file and takes the union of what they suggest, so a single dark scene cannot
make it over-crop.

Use `--trim-bars off` if a particular file comes out wrongly cropped.

## Options

Run `./convert.sh --help`.

The ones worth knowing: `--profile`, `--size`, `--rotate`, `--fit`
(`crop`/`pad`/`stretch`), `--trim-bars`, `--jobs N`, `--force`, `--dry-run`.

`--fit pad` is the escape hatch if cropping loses words on a page that runs text
edge to edge: it letterboxes instead, keeping the whole frame at a smaller size.

## Tests

```
./scripts/smoke.sh                 # synthetic end-to-end, ~66 assertions
./scripts/smoke.sh --verify-fails  # proves those assertions can go red
./scripts/smoke.sh --target <dir>  # validate a folder or SD card of AVIs
```

The suite drives `convert.sh` as a subprocess rather than sourcing its
functions, so it cannot pass against a code path the script no longer uses. It
checks pixels, not just metadata: the rotation test builds a red-left/blue-right
source and asserts red ends up on top, which is the only thing that catches a
rotation applied backwards or not at all.

## Layout

```
convert.sh              the tool
scripts/smoke.sh        tests
videosToConvert/        put sources here
converted/              output
testclips/              device test clips
logs/                   ffmpeg output, one file per run
UserStories.md          what this does, and what is verified
TechFromUserStories.md  how it does it
```
