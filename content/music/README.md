# Music tracks

Each track is a tracker module: a bank of sampled instruments plus a
pattern sequence. This is the same sampled-sequence model the
PlayStation SPU used, so one module per track feeds both the
software-mixed targets (rendered by libxmp) and a VAB/SEQ bake on PSX.

The baker bundles each file verbatim as a pak lump. libxmp identifies
the format at load time, so any of `.xm`, `.it`, `.s3m` or `.mod` works.

## Tracks

The Makefile maps each lump to a base filename:

| Lump          | File             | Plays during        |
|---------------|------------------|---------------------|
| `MUS_TITLE`   | `title.*`        | title and party setup |
| `MUS_TOWN`    | `town.*`         | the town map        |
| `MUS_DUNGEON` | `dungeon.*`      | dungeon levels      |
| `MUS_COMBAT`  | `combat.*`       | encounters          |

Drop a module at the matching base name and rebuild. A missing file is
not an error; that track just stays silent.

## Placeholders

The `*.mod` files here are silent placeholders: a valid but empty M.K.
module, present only to exercise the pipeline. Replace them with real
tracks. Favour small modules with looping patterns rather than long
streamed audio, to stay within the PSX sound-RAM budget.

## Playback requires libxmp

The software targets render modules with libxmp, loaded at runtime. If
it is absent the sound effects still play and music is silent. On
Debian or Ubuntu: `apt-get install libxmp4`.
