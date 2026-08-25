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

That writes twelve short clips to `testclips/`: four codec profiles crossed with
three orientation strategies. Copy the folder to the player and note which
filenames actually play, and which one fills the screen.

Add `--profile <name>` to build just one profile, so a second round does not
rebuild formats the player has already rejected:

```
./convert.sh --test-clips --profile amv
```

**2. Convert everything, using whatever won.**

```
./convert.sh --profile amv --size 128x160 --rotate 90
```

Output lands in `converted/`. Re-running skips files that are already done, so
an interrupted batch resumes where it left off.

**3. Check the card before you trust it.**

```
./scripts/smoke.sh --target /media/bob/ANKO
```

Reads every `.avi` or `.amv` on the card and confirms they all agree on
geometry and codec.

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

| Profile | Container | Video | Audio | 5 min video | When |
|---|---|---|---|---|---|
| `amv` | `.amv` | AMV | IMA ADPCM 22 kHz mono | ~15 MB | **Default.** What this class of player was built for. |
| `mjpeg` | `.avi` | MJPEG | PCM 22 kHz mono | ~27 MB | Widest AVI compatibility. |
| `xvid` | `.avi` | Xvid | MP3 64 kbps | ~4 MB | Small. Needs a real Xvid decoder. |
| `mpeg4` | `.avi` | MPEG-4 SP | MP3 64 kbps | ~4 MB | Same size as xvid, different encoder and FourCC. |

Reading the failure mode matters:

- **"Video Format Not Supported"** — the container is being rejected, not the
  codec. Trying a different codec in the same container will not help.
- **Black screen, audio plays** — the container is fine, the video codec is not.
- **Plays but tears or drifts** — try the next profile, or drop `--fps`.

The Anko unit these were built against rejects all three AVI profiles across all
three geometries, which is what AMV is here for.

### AMV constraints

The encoder and muxer are strict, and ffmpeg's own errors do not explain why.
`convert.sh` checks these up front:

- Height must be a **multiple of 16**. 128x160 and 160x128 are fine; 160x120 is not.
- Audio is always **22050 Hz mono**. No other rate opens the encoder.
- `--fps` must **divide 22050 exactly**: 5, 6, 7, 9, 10, 14, 15, 18, 21, 25, 30.
  The default 15 is fine.
- Internally the audio `-block_size` must equal `22050/fps`. Get it wrong and the
  header will not write at all. The tool computes it.

AMV files carry no duration field, so a player may show no progress bar or an odd
running time. That is normal for the format, not a broken conversion.

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

## When nothing plays

```
./scripts/probe-pack.sh
```

Builds nine labelled clips into `testclips/` that vary one property at a time:
container, file extension, and resolution. Copy them all to the player; whichever
one plays identifies the variable that mattered.

The two things worth reading carefully on the device:

- **Is the file listed at all?** If it is not, the browser filtered it out by
  extension and the contents were never examined. This unit lists `.avi` and does
  not show `.amv`, which is what `--ext` exists for.
- **Listed but "Format Not Supported"?** The contents were examined and rejected.

## Tests

```
./scripts/smoke.sh                 # synthetic end-to-end, 98 assertions
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
converted/              output (.amv or .avi, per profile)
testclips/              device test clips
logs/                   ffmpeg output, one file per run
UserStories.md          what this does, and what is verified
TechFromUserStories.md  how it does it
```
