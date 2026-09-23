# Port the real install-tree delivery (r159 squashfs stub) into the new writer

## Context

This repo is `cix-installer` (NCZ-OS build system), branch
`wip/incremental-iso-writer-2026-09-21` (checked out on ACHILLES at
`~/Projects/iso-writer-step1` and pushed to ARGONAS as commit `b6a6754`+).
The design doc is
`docs/superpowers/specs/2026-09-21-incremental-di-iso-assembly-design.md`
— read it, especially the component table.

**We are NOT replacing Debian Installer.** d-i itself, its boot flow, its
preseed model — all stay exactly as they are (real, stock, unpatched
Forky d-i). What's being replaced is the ISO ASSEMBLY: the old
`build/build-iso-di.sh` is a single 3800-line monolithic script that
does a full rebuild every time; the new pipeline
(`build/iso/write-image.py`, `build/iso/build-refind-esp.py`,
`build/iso/import-substrate.py`, `build/iso/verify-image.py`) is a
content-addressed, incremental replacement for JUST the assembly step.

Step 1 of that migration (already done, verified today) got the new
writer producing a real, boot-verified ISO — confirmed via real OVMF +
real `-cdrom` El Torito attach on ACHILLES, reaching all the way to d-i's
debconf preconfiguration prompt. See
`docs/superpowers/specs/evidence/2026-09-22-achilles-real-cdrom/`.

**What's missing**: that verified ISO uses a stock upstream Debian d-i
substrate (`import-substrate.py` pulls the real Debian netboot ISO) with
NO local install-tree payload — d-i would try to do a live network
install if driven further. The OLD `build-iso-di.sh` pipeline had a real
mechanism for shipping our actual install tree (the `base.squashfs` +
`desktop.squashfs` layers our mkosi-based build produces via
`mmdebstrap`/`build-squashfs-layers.sh`) locally on the ISO, consumed by
d-i's OWN base-installer component. Your job: port that mechanism into
the NEW assembly pipeline, without touching `build-iso-di.sh` itself
(it's being retired, not maintained further) and without touching d-i.

## The mechanism (read this carefully — it's real, working code, not a spec)

d-i's `base-installer` component historically calls `/usr/sbin/debootstrap`
inside the installer runtime to bootstrap the target rootfs. NCZ-OS
ships a `.udeb` package (`debootstrap-udeb`) whose `/usr/sbin/debootstrap`
is REPLACED with a stub shell script (the "r40"/"r159" stub) that instead:

1. Looks for `/cdrom/cixmini/base.squashfs` (also checks
   `/hd-media/cixmini`, `/media/cdrom/cixmini`, `/run/live/medium/cixmini`
   — first match wins).
2. `unsquashfs`'s `base.squashfs` onto `$TARGET` (the real target disk d-i
   mounted) using a BUNDLED, architecture-matched static `unsquashfs` +
   loader from `$SQDIR/sqtools/` (NOT the installer environment's own
   `unsquashfs`, which doesn't exist there).
3. Applies `desktop.squashfs` as a delta overlay on top, driven by a
   companion `desktop.overlay-manifest` file (tab-separated `kind<TAB>rel`
   lines, `kind` is `whiteout` or `opaque`) that tells it which paths to
   `rm -rf` before extracting the delta (this reproduces overlayfs
   upperdir semantics without a kernel overlay mount).
4. Exits 0 so base-installer believes debootstrap succeeded, and d-i's
   later steps proceed normally against the now-populated `$TARGET`.

Full reference implementation: `build/build-iso-di.sh` lines ~1076-1360
on this branch (the exact stub script is a `cat > ... <<'STUB'` heredoc
starting around line 1093; the squashfs-consumption logic — including the
component-selector, overlay-manifest whiteout/opaque handling, and the
2026-08-26 root-mode gate documented in `docs/ISO-BUILD-GUARDRAILS.md`
— runs from roughly line 1140 to 1360). **Copy this logic, don't
reimplement it from scratch** — it has several hard-won correctness fixes
(the 0700-root incident, the ARM64-unsquashfs-on-AMD64-installer
silent-failure trap, the missing-overlay-manifest gate) baked in as
comments explaining exactly why each check exists. Read those comments,
keep the checks.

## What "done" means

1. A new script, `build/iso/stage-cixmini-payload.py` (or `.sh`, your
   choice, match the style of the existing `build/iso/*.py` scripts if
   Python), that:
   - Takes `assets/squashfs/base.squashfs`, `assets/squashfs/desktop.squashfs`,
     `assets/squashfs/desktop.overlay-manifest` (already built — check
     they exist on ACHILLES at `~/Projects/iso-writer-step1/assets/squashfs/`
     as of this session; if not yet present, run
     `NCZ_TARGET_ARCH=amd64 NCZ_SKIP_FRESHNESS_GATE=1 ARTISTPACK_SOURCE_ROOT=/home/jasonperlow/Projects/artistpack/packs bash build/build-squashfs-layers.sh all`
     under `sudo` first — real mmdebstrap/mkosi pipeline, takes real
     time, real network).
   - Stages `build/sqtools-amd64/` (already exists in this checkout — the
     static unsquashfs+loader bundle, already amd64-matched — see
     `build-iso-di.sh` line ~3449-3459 for why the arch match matters:
     an ARM64 unsquashfs on an AMD64 installer fails silently, nothing
     extracted, confirmed 2026-09-15).
   - Applies the SAME root-mode gate `build-iso-di.sh` uses
     (`assert_squashfs_root_mode`, ~line 3438) before staging — refuse to
     stage a squashfs whose root entry isn't mode 0755.
   - Produces a staged tree at (say) `build/iso-cache/v1/cixmini-payload/`
     with `base.squashfs`, `desktop.squashfs`, `desktop.overlay-manifest`,
     `sqtools/` — ready to be copied verbatim into an ISO's `/cixmini/`
     top-level directory.

2. A new script, `build/iso/patch-debootstrap-stub.py` (or `.sh`), that:
   - Locates the substrate's real `debootstrap-udeb_*_all.udeb` (find
     where `import-substrate.py`'s extracted tree puts the ISO's package
     pool — check its `root/` output category, since `pool/` normally
     lives at ISO top-level on a netinst image; verify by actually
     inspecting a real imported substrate tree on ACHILLES rather than
     guessing).
   - `ar x`'s it, extracts `data.tar*`, overwrites `usr/sbin/debootstrap`
     with the stub shell script (copy VERBATIM from `build-iso-di.sh`'s
     heredoc, lines ~1094-1360 as scoped above — it's POSIX shell,
     version-agnostic, not bookworm-specific despite old comments
     mentioning bookworm by name; you can genericize the comments but
     don't change the logic), repacks as a valid `.udeb` (ar archive:
     `debian-binary`, `control.tar*`, `data.tar*`, same member order/
     compression as the original).
   - Writes the patched udeb back into the staged substrate tree at the
     same pool path, replacing the original.
   - **Also assert the 3 udebs `build-iso-di.sh` asserts are present**
     (`debootstrap-udeb`, `libzstd1-udeb`, `liblzma5-udeb`) and the 3
     required d-i runtime udebs (`cdebconf-udeb`, `cdebconf-newt-udeb`,
     `hw-detect`) — real gaps if any are silently missing from the
     Forky substrate (main-menu wedges without cdebconf-newt-udeb's
     templates; disk-detect fails without hw-detect, per the existing
     comment in build-iso-di.sh line ~1035).

3. Wire both into `build/iso/write-image.py`'s `cold_image()` (and warm
   growth path, if you get to Task 3 of `STEP1-CONTINUATION-BRIEF.md` —
   not required for this task, but don't make the wiring incompatible
   with it): the ISO9660 tree needs `/cixmini/*` present, and the
   substrate's pool needs the patched debootstrap-udeb instead of the
   stock one, BEFORE `write-image.py` composes the final ISO.

4. **Real verification, not a claim**: boot the resulting ISO under real
   OVMF + `qemu-system-x86_64` on ACHILLES the same way Step 1's evidence
   did (see `docs/superpowers/specs/evidence/2026-09-22-achilles-real-cdrom/README.md`
   for the exact invocation — use real `-cdrom`, NOT `-drive if=virtio`,
   that distinction mattered and was previously undisclosed as a
   deviation — don't repeat that mistake). Drive far enough into d-i
   (auto preseed or manual selection) that base-installer actually
   INVOKES the stub — the serial log must show real stub output:
   `"I: r159 stub: LAYERED SQUASHFS install from ..."`,
   `"I: r159 stub: unsquashfs base -> ..."`, and (if you can drive it
   that far) `"I: r159 stub: applied N desktop overlay operation(s)"`.
   Getting all the way to a fully-partitioned, fully-installed virtual
   disk is a stretch goal (needs a real preseed + a blank target
   `-drive`) — if you don't reach it, say so plainly and report exactly
   how far you got and why, per this branch's standing verification
   discipline (no overclaiming, cite the actual log lines, never
   reference a `/tmp` path that won't survive — commit the real log as
   evidence the same way prior Step 1 rounds did).

## Hard constraints

- Do NOT touch `build/build-iso-di.sh`, `preseed/`, or `post-install/`.
- Do NOT touch d-i itself or `import-substrate.py`'s substrate source
  (still the real stock Debian netboot ISO for Forky).
- Real assets only — no synthetic/toy squashfs, no invented udeb bytes.
  If `assets/squashfs/*.squashfs` aren't built yet when you start, build
  them for real first (command above); this can take real wall-clock
  time (mmdebstrap + full package installs), budget for it.
- Commit each real milestone separately (payload staging script, stub
  patcher, write-image.py wiring, evidence) as you go — don't batch.
  Push to `ssh://root@192.168.207.101/mnt/datapool/git/cix-installer.git`
  (the `jasonperlow@` form of that URL is pubkey-only and will fail).
  **Re-fetch and rebase onto the current remote tip immediately before
  every push** — this branch has had concurrent-push collisions this
  session (a previous evidence commit needed a rebase against another
  session's identical-content-different-hash commits); never force-push,
  never blindly reset-and-reapply.

## Verification setup — TYDEUS pair, not MiniMax alone

Author with MiniMax-M3, but wire a REAL adversarial reviewer + a REAL
automated check gate this time (a prior round on this exact branch
skipped both and let a fabricated evidence claim through review):

- `--reviewer reviewer` (routes to TYDEUS's local reviewer slot; re-probe
  `http://192.168.207.73:8006/v1/models` yourself before trusting any
  cached claim about what model backs it — it rotates).
- `--check "python3 -m py_compile build/iso/*.py"` at minimum; add a
  stronger check if you can (e.g. a script that asserts the staged
  `/cixmini/` tree has all 4 expected files and the patched udeb's
  `ar t` listing still has exactly 3 members).
- `--agent-timeout 7200` (the default 900s silently kills long runs —
  confirmed on this branch's own history).

This is real infrastructure work that determines whether NCZ-OS actually
installs anything real from the new pipeline — verify like it matters.
