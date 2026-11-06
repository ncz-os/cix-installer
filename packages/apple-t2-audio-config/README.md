# apple-t2-audio-config (NCZ-OS, data-only ALSA UCM)

A fresh, reproducible, **data-only** replacement for the UCM payload that
`post-install/55-t2-firmware.sh` installs from a third-party apt repository on
T2 Macs. Same package name, same six paths, same HiFi interface contract -
new, independently written configuration text in **real ALSA use case manager
syntax, version 6**.

* Package: `apple-t2-audio-config`, version **`0.5.1+ncz1`** (Debian `newer`
  than the installed `0.5.1`, so `apt` upgrades in place with **no removals**),
  architecture `all`.
* Depends: **`alsa-ucm-conf (>= 1.2.16)`** - the observed targets had no
  `alsa-ucm-conf` and therefore no
  `/usr/share/alsa/ucm2/common/pcm/split.conf`. The Forky (Debian Testing)
  candidate is `1.2.16.1-1`; the explicit dependency installs the split-PCM
  macro interface the speaker path uses.
* No DSP, no filters, no speaker-protection blocks, no WirePlumber or PipeWire
  payload, no test sounds, no mixer or volume changes, no maintainer scripts
  (installing or upgrading restarts nothing).
* `/etc/pipewire/pipewire.conf.d/99-ncz-audio-headroom.conf` is **not** touched.

## Layout

| Path | Purpose |
|---|---|
| `build-deb.sh` | generate + build the `.deb` (deterministic, offline) |
| `src/applet2_ucm.py` | the generator (Python 3 standard library only) |
| `src/facts.json` | the transcribed interface facts, validated at build time |
| `tests/test_contract.py` | key/channel/path/API contract and refusal tests |
| `LICENSE` | MIT, (c) 2026 Jason Perlow |

Generated files never land in the source tree: the generator refuses an
`--out-dir` that lives inside this package.

## Recipe

Everything is written under `~/Projects`, and `TMPDIR` is pointed inside it as
well, so no scratch ever lands in a system temporary directory or in a user
cache directory. Run from the repository root.

```bash
# 0. A scratch parent under ~/Projects for this package, and a TMPDIR with it.
mkdir -p ~/Projects/ncz-build/runtime
export TMPDIR=~/Projects/ncz-build/runtime

# 1. Generate the staging tree only - every argument is validated first.
packages/apple-t2-audio-config/build-deb.sh --stage-only --keep-staging --out-dir ~/Projects/ncz-build/out --scratch-parent ~/Projects/ncz-build

# 2. Generate and build the .deb (one line, all outputs outside the source tree).
packages/apple-t2-audio-config/build-deb.sh --out-dir ~/Projects/ncz-build/out --scratch-parent ~/Projects/ncz-build --source-date-epoch 1792022400

# 3. Inspect it without installing it.
DEB=~/Projects/ncz-build/out/apple-t2-audio-config_0.5.1+ncz1_all.deb
dpkg-deb --info    "$DEB"
dpkg-deb --contents "$DEB"
dpkg-deb --extract  "$DEB" ~/Projects/ncz-build/extracted

# 4. Tests.
python3 -m unittest discover -s packages/apple-t2-audio-config/tests -v
# or: python3 packages/apple-t2-audio-config/tests/test_contract.py
```

Options: `--layout all|2|4|6` (default `all`: one card/use-case pair per
channel count), `--stage-only`, `--keep-staging`, `--source-date-epoch N`.
If a fresh checkout has not marked the script executable, invoke it as
`bash packages/apple-t2-audio-config/build-deb.sh ...`.

## Scratch ownership (the rule this build script follows)

The build script **never deletes a directory it did not create**.

1. Every argument is checked first: `--out-dir` must be absolute, outside the
   source tree, not a system directory, not a symlink, and empty or absent;
   `--scratch-parent` must be absolute, must be inside `~/Projects`, must
   contain **no symbolic-link component** (the physical path has to equal the
   literal one), and must not be inside `--out-dir` or the source tree. A parent may
   contain separate output and exclusive staging children.
2. The layout, the facts document and the output path are then validated by
   `applet2_ucm.py --validate-only`, which **creates nothing**.
3. Only then does the run allocate **one exclusive child** with `mktemp -d`
   inside the validated parent.
4. On exit, an `EXIT` trap removes **exactly that child**, and only after
   re-checking that it is still a directory directly inside the validated
   parent and that its name carries this run's `mktemp` prefix. The caller's
   parent directory and anything already in it are never touched; a non-empty
   `--out-dir` is refused with its contents intact.

An invalid argument, an unknown layout or an invalid facts document is
rejected before any `mkdir`, including before the output directory exists.

## Reproducibility

* Payload bytes are a pure function of `src/facts.json` plus `LICENSE`.
* All files are 0644 and directories 0755, independently of the build host's
  umask; the staging tree is owned root in the `.deb`
  (`dpkg-deb --root-owner-group`).
* `--source-date-epoch` (default `1792022400`, also read from the environment)
  sets every file timestamp and the Debian changelog date; the gzip changelog
  is written with mtime 0 and a fixed compression level.
* Building twice with the same inputs produces identical file contents;
  `sha256sum` of the `.deb` is printed by the build script.

## What the package ships (the six-path contract)

```
/usr/share/alsa/ucm2/AppleT2/HiFi-x2.conf
/usr/share/alsa/ucm2/AppleT2/HiFi-x4.conf
/usr/share/alsa/ucm2/AppleT2/HiFi-x6.conf
/usr/share/alsa/ucm2/conf.d/AppleT2x2/AppleT2x2.conf
/usr/share/alsa/ucm2/conf.d/AppleT2x4/AppleT2x4.conf
/usr/share/alsa/ucm2/conf.d/AppleT2x6/AppleT2x6.conf
```

plus `/usr/share/doc/apple-t2-audio-config/{copyright,changelog.Debian.gz}` and
the `DEBIAN/` metadata. Nothing else.

Each `conf.d/<card>/<card>.conf` is a **Syntax 6 card configuration** whose only
job is to bind the verb to the use case file this package generates for that
layout:

```
Syntax 6

SectionUseCase."HiFi" {
	File "/AppleT2/HiFi-x6.conf"
	Comment "AppleT2x6, 6-channel speaker layout."
}
```

Each `AppleT2/HiFi-x<n>.conf` is the **use case master configuration**: it
includes the shipped split-PCM macro interface, defines the speaker stream
once with `SplitPCM`, publishes the verb with `SectionVerb`, and describes
every route as a `SectionDevice` with the standard `Value` keys
(`PlaybackPCM`, `PlaybackChannels`, `PlaybackPriority`, `CapturePCM`,
`CaptureChannels`, `CaptureRate`, `CapturePriority`, `JackControl`).
Conflicts use the standard section-level `ConflictingDevice` array.

The interface contract, all of it from observation on two AppleT2x6 systems and
from the x2/x4 variants in the same installed package:

| Device | Direction | Hardware PCM | Channels | Priority | Conflict | Jack | Rate |
|---|---|---|---|---|---|---|---|
| Speaker | playback | 0 | all hardware channels of the layout | 100 | - | - | - |
| Headphones | playback | 2 | 2 | 300 | Speaker | `Codec Output Jack` | - |
| Mic | capture | 1 | 3 | 300 | Headset | - | 48000 |
| Headset | capture | 3 | 1 | 200 | Mic | `Codec Output Jack` | - |

Speaker channel positions per layout: x2 `FL FR`; x4 `FL FR RL RR`;
x6 `FL SL RL FR SR RR`. Format `S24_LE`, UCM syntax version 6, verb `HiFi`.

**The speaker keeps every physical channel.** For each layout the application
channel count equals the hardware channel count and the channel map is the
identity map over that layout's own positions (`Channel0 0` ... `ChannelN-1
N-1`, `ChannelPos0 ... ChannelPosN-1`), so a two-channel MacBook, a four-channel
one and a six-channel one all get their full speaker stream. There is no
stereo-only projection and no invented "application channels" count.

## Sources and independent-implementation boundary

Read and used as permitted:

1. **`.scratch/context/HARDWARE-FACTS.json`** in this repository - factual
   ALSA interface/route data (card names, PCM device numbers, channel counts
   and positions, priorities, conflicts, jack control, capture rate) recorded
   on two AppleT2x6 systems and for the x2/x4 variants. No host identity from
   that record is reproduced anywhere in this package.
2. **`.scratch/context/alsa-public/`** - the public ALSA UCM material from
   `alsa-ucm-conf` at pinned upstream commit
   **`d260eedd1900dbf3b477047e048d5382a5f50e24`**: `LICENSE` (BSD 3-Clause,
   (c) 2019 Advanced Linux Sound Architecture (ALSA) project), `README.md`
   (the ucm2 lookup scheme and value-name grammar) and the `common/pcm/split.conf`
   macro interface. Those notices are retained in `DEBIAN/copyright` and in
   every generated `copyright` file, and the dependency on that package is
   declared in `Depends`.

The primary coding author received only the fact table and public BSD ALSA
syntax/macro references, not the disputed T2 configurations or derivative UCM
files. The supervisor inspected the installed baseline to extract facts and
made narrow standard-grammar corrections after unsuccessful author candidates.
No disputed configuration blobs or expressive comments were copied. Required
ALSA identifiers and route facts are retained; new descriptive text and
implementation are authored here. This is an independent functional
implementation, not a claim that the older material's licensing was resolved.
No DSP, protection code or filters from that material are imported.

The kernel T2 driver (GPL) is unrelated to this userspace package and is not
touched by it.

**Copyright.** The generator, the generated UCM files, the build script and the
tests are (c) 2026 Jason Perlow, MIT (see `LICENSE`). The `alsa-ucm-conf`
dependency is (c) the ALSA project, BSD 3-Clause; it is not vendored here.

## What the tests do and do not prove

`tests/test_contract.py` asserts the **contract**: the six paths, the real
Syntax 6 shape of each file kind, the card file's `File` value pointing at the
use case file this run generated, every route's `Value` keys and numbers, the
full-channel speaker map, package metadata, file modes, byte-for-byte
determinism, every refusal, and the build script's scratch-ownership rules.

They deliberately contain **no UCM parser** and no claim of an ALSA parse.
Runtime parsing is verified separately from these tests. Two actual AppleT2x6
systems accepted the generated profiles with alsa-utils 1.2.16-1 and
libasound2t64 1.2.16.1-2, using the exact signed Forky snapshot
20261012T023456Z alsa-ucm-conf 1.2.16.1-1 macro. The macro SHA256 is
4722263e1ecb26a42f88005acb6aca768991d7e260e862285a814bfa9224851d.
All speaker channels, three other routes, priorities, jack metadata and
microphone rate were queried; malformed syntax was rejected. The x2/x4 cases
were parser fixtures using the actual x6 control card, not tests on physical
x2/x4 hardware. No playback, recording, mixer changes or service changes ran.

To repeat a read-only route query, unpack this package and the signed
alsa-ucm-conf package into a fresh root under Projects. Verify the card number
in /proc/asound/cards first; hw:0 below must identify the T2 card.

```bash
STAGED_UCM=~/Projects/ncz-build/extracted/usr/share/alsa/ucm2
printf '%s\n' 'set _verb HiFi' 'list _devices' 'get PlaybackChannels/Speaker' \
  | ALSA_CONFIG_UCM2="$STAGED_UCM" alsaucm -c hw:0 -b -
```

This selects a verb only within the query process; these generated profiles
contain no enable/disable control sequences and open no playback/capture PCM.
Actual sound quality, protected speaker playback and microphone recording are
outside this validation. Existing PipeWire/DSP/headroom configuration is not
modified by this package or these tests.
