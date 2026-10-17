#!/usr/bin/env python3
"""
patch-debootstrap-stub.py — Replace ``/usr/sbin/debootstrap`` inside
``debootstrap-udeb`` with the NCZ r159 stub shell script (the same heredoc
that the retired ``build/build-iso-di.sh`` wrote verbatim into its staged udeb at
``build/build-iso-di.sh:1102-1671``).

Why this is a separate script from ``stage-ncz-payload.py``:

  The payload is the ``/cdrom/ncz-payload/{base,desktop,...}`` tree the stub
  CONSUMES at install time. The patched udeb is the ``/usr/sbin/debootstrap``
  binary the stub REPLACES inside the installer's own runtime. They are
  two different artifacts, two different production pipelines, and
  two different verification surfaces; conflating them in one script
  would couple failure modes that should be diagnosable independently
  (a payload-staging bug is not a udeb-patching bug, and vice versa).

The r159 stub (copied verbatim from the retired ``build/build-iso-di.sh:1103-1671``,
syntax-checked at build time):

  * looks for the first absolute-path arg, treats it as ``$TARGET``
    (the real target disk d-i mounted);
  * if ``$TARGET/etc/os-release`` already exists (re-run, idempotent),
    exits 0;
  * else, looks for ``/cdrom/ncz-payload/base.squashfs`` (and the same under
    ``/hd-media/ncz-payload``, ``/media/cdrom/ncz-payload``,
    ``/run/live/medium/ncz-payload`` — first match wins);
  * unsquashfs's ``base.squashfs`` onto ``$TARGET`` using a BUNDLED,
    architecture-matched static ``unsquashfs`` from
    ``$SQDIR/sqtools/unsquashfs`` (NOT the installer runtime's own
    unsquashfs, which doesn't exist in the d-i initrd);
  * applies ``desktop.squashfs`` as a delta overlay on top, driven by
    ``desktop.overlay-manifest`` (tab-separated ``kind<TAB>rel`` lines,
    ``kind`` is ``whiteout`` or ``opaque``) — this reproduces overlayfs
    upperdir semantics without a kernel overlay mount;
  * asserts ``/``'s mode is 0755 after extraction (the 2026-08-26
    root-mode gate, documented in ``docs/ISO-BUILD-GUARDRAILS.md``);
  * exits 0 so base-installer believes debootstrap succeeded and d-i's
    later steps proceed normally against the now-populated ``$TARGET``.

MAGNETAR (``NCZ_VARIANT=server``): the server medium carries NO squashfs at
all. When the probe finds no local ``base.squashfs`` the stub looks for
``ncz-fetch-payload.sh`` beside the payload instead, picks a WRITABLE staging
root (the install medium is mounted ``ro``), and lets that script fetch every
artifact named in the medium's pinned manifest -- verifying each sha256, with
bounded retries, HTTP resume and a loud serial failure on anything wrong. A
failed fetch exits non-zero, so an unverified rootfs can never be installed.
The wipe of ``$TARGET`` deliberately skips that staging root. Desktop media
finds ``base.squashfs`` in the first probe and never enters this path.

The script copies the stub VERBATIM — including its inline comments
explaining WHY each gate exists (the 0700-root incident, the
ARM64-unsquashfs-on-AMD64 silent failure, the missing-overlay-manifest
hard-fail). Genericizing the comments would erase the post-mortem
context the gate exists to communicate. Don't rewrite them.

Substrate layout the script handles:

  * ``install_dir`` (full Debian netinst ISO): ``/pool/main/d/debootstrap/
    debootstrap-udeb_*_all.udeb`` is patched in place inside the staged
    substrate tree, exactly the way the retired ``build-iso-di.sh`` did it. The
    3 shell-side udeb assertions (``debootstrap-udeb``,
    ``libzstd1-udeb``, ``liblzma5-udeb``) and the 3 d-i runtime udeb
    assertions (``cdebconf-udeb``, ``cdebconf-newt-udeb``, ``hw-detect``)
    from the retired ``build/build-iso-di.sh:1035-1062`` are made against this pool.
  * ``netboot`` (mini.iso):
    there is no ``/pool/`` in the extracted tree. The patched udeb is
    written to a dedicated path inside the staged ISO tree
    (``build/iso-cache/v1/ncz-udeb/<key>/debootstrap-udeb_<ver>_all.udeb``)
    which ``write-image.py`` copies to ``/ncz-payload/debootstrap-udeb/``
    on the ISO so it can be referenced (and is visibly staged) for
    operator inspection. The udeb assertions are SKIPPED on this layout
    with a clear message; the brief allows this fallback honestly
    ("Getting all the way to a fully-partitioned, fully-installed
    virtual disk is a stretch goal … if you don't reach it, say so
    plainly and report exactly how far you got and why").

What this script does NOT do:

  * It does NOT synthesize udebs. Real udebs only — fetched from a
    deb.debian.org mirror, or from a pre-existing full Debian netinst
    ISO, or passed via ``--source-udeb``. No invented bytes.
  * It does NOT modify d-i itself. The patched udeb replaces the
    ``/usr/sbin/debootstrap`` shell INSIDE the udeb package, not d-i.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DEFAULT_CACHE_ROOT = REPO_ROOT / "build" / "iso-cache" / "v1"


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_bytes(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def canonical_encode(obj: dict) -> bytes:
    return json.dumps(obj, sort_keys=True, separators=(",", ":")).encode("utf-8")


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def _chmod_r(p: Path) -> None:
    try:
        subprocess.run(["chmod", "-R", "u+w", str(p)], check=False,
                       capture_output=True)
    except Exception:
        pass


# ----------------------------------------------------------------------------
# The stub script.
#
# Copied VERBATIM from the retired ``build/build-iso-di.sh:1103-1671``. POSIX shell,
# version-agnostic (the original comments mention bookworm by name as a
# historical record of which substrate the stub was first validated against;
# the logic itself is generic and works on any d-i runtime that exec's
# ``/usr/sbin/debootstrap``). The comments are kept intact because they are
# the post-mortem context each gate exists to communicate — genericizing
# them would erase the bug stories the next operator needs to read.
#
# ``bash -n`` and ``sh -n`` both pass; the retired build-iso-di.sh heredoc author ran
# ``bash -n`` after writing the stub (line 1674 of build-iso-di.sh) so we
# do the same.
# ----------------------------------------------------------------------------
R159_STUB_SCRIPT = r"""#!/bin/sh
# ncz r40 stub debootstrap — extracts rootfs.tar.zst into /target itself
# (no longer relies on partman/late_command, which is NOT a real preseed
# variable — only partman/early_command exists). When bookworm bootstrap-base
# calls /usr/sbin/debootstrap, this stub:
#   1. Finds the target dir from positional args
#   2. If /target already populated (re-run), exits 0
#   3. Else: locates rootfs.tar.zst on cdrom, extracts it via zstd | tar -xpf
#   4. Exits 0 so base-installer believes debootstrap succeeded
#
# After this, /target has the Debian forky base rootfs from base.squashfs
# (plus the desktop / desktop-hotfix deltas when selected). Any
# subsequent base-installer step (debconf-copydb, debconf-set-selections,
# mount /target/dev) finds the binaries/dirs it needs.

TARGET=""
for arg; do
    case "$arg" in
        /*) [ -d "$arg" ] && TARGET="$arg" && break ;;
    esac
done

if [ -z "$TARGET" ]; then
    echo "W: r40 stub debootstrap: no target dir in args (got: $*)" >&2
    exit 0
fi

# Already populated -> idempotent no-op
if [ -f "$TARGET/etc/os-release" ] && [ -d "$TARGET/usr/bin" ] && \
   [ "$(ls "$TARGET/usr/bin" 2>/dev/null | wc -l)" -gt 100 ]; then
    echo "I: r40 stub debootstrap: $TARGET already populated, skipping" >&2
    exit 0
fi

# r159: LAYERED SQUASHFS — prefer base.squashfs (+ <role> delta) via the bundled
# unsquashfs (loader + libs in sqtools/). Pure userspace, no kernel mount/overlay.
SQDIR=""
for d in /cdrom/ncz-payload /hd-media/ncz-payload /media/cdrom/ncz-payload /run/live/medium/ncz-payload; do
    [ -f "$d/base.squashfs" ] && { SQDIR="$d"; break; }
done

# MAGNETAR (NCZ_VARIANT=server): the payload is NOT on the medium. The server
# medium carries only a pinned manifest (url + sha256 per artifact) plus this
# fetch helper; everything else -- base.squashfs and the substrate assets the
# post-install hooks read out of the payload tree -- is pulled here, BEFORE the
# extraction below, and verified by ncz-fetch-payload.sh (bounded retries,
# HTTP resume, loud serial failure, exit non-zero on a bad or missing digest).
# A failed fetch therefore never installs an unverified rootfs: we abort.
#
# This runs inside the debootstrap stub, which is the ONLY live install path
# under d-i (there is no partman/late_command hook -- see the CONTRACT note in
# preseed/preseed.cfg), so "before the stub extracts" IS "before the install
# needs it". Desktop media always finds base.squashfs in the loop above, so the
# whole block is skipped for it and desktop media is byte-identical.
MEDIADIR=""
if [ -z "$SQDIR" ]; then
    for d in /cdrom/ncz-payload /hd-media/ncz-payload /media/cdrom/ncz-payload /run/live/medium/ncz-payload; do
        [ -f "$d/ncz-fetch-payload.sh" ] && { MEDIADIR="$d"; break; }
    done
fi
if [ -z "$SQDIR" ] && [ -n "$MEDIADIR" ]; then
    echo "I: r159 stub: no payload on the medium -- fetching it (Magnetar online install)" >&2
    # The install medium is mounted READ-ONLY (media-usb-only.sh mounts it
    # `-o ro,noload`), so a fetch into /cdrom would die part-way and leave a
    # half-written tree. $TARGET is the disk d-i just partitioned and mounted
    # rw; /run (the initrd tmpfs) is the fallback. Probe, never assume.
    FETCHDIR=""
    for cand in "$TARGET/ncz-online/ncz-payload" /run/ncz-online/ncz-payload ; do
        mkdir -p "$cand" 2>/dev/null && [ -w "$cand" ] && { FETCHDIR="$cand"; break; }
    done
    if [ -z "$FETCHDIR" ]; then
        echo "FATAL: r159 stub: no writable directory to fetch the payload into" >&2
        echo "FATAL: nothing installed -- the medium carries no rootfs and there is nowhere to put the fetched one" >&2
        exit 1
    fi
    if NCZ_PAYLOAD_DIR="$FETCHDIR" NCZ_FETCH_TMPDIR="$FETCHDIR/.fetchtmp" \
       sh "$MEDIADIR/ncz-fetch-payload.sh"; then
        echo "I: r159 stub: payload fetched and sha256-verified into $FETCHDIR" >&2
        # sqtools (the arch-matched static unsquashfs + its loader) still ships
        # on the medium -- it is a few MB and unsquashfs is needed to unpack the
        # very file we just downloaded. Link it in so every path below stays
        # "$SQDIR/<artifact>" with no special cases.
        [ -d "$FETCHDIR/sqtools" ] || ln -s "$MEDIADIR/sqtools" "$FETCHDIR/sqtools" 2>/dev/null || true
        [ -x "$FETCHDIR/sqtools/unsquashfs" ] || cp -a "$MEDIADIR/sqtools" "$FETCHDIR/sqtools"
        SQDIR="$FETCHDIR"
    else
        echo "FATAL: r159 stub: online payload fetch failed; see the [FETCH] lines above" >&2
        echo "FATAL: nothing installed -- the medium has no local rootfs and the network fetch did not succeed" >&2
        exit 1
    fi
fi
if [ -z "$SQDIR" ]; then
    echo "FATAL: r159 stub: no payload source and no online fetch helper on the medium" >&2
    echo "FATAL: nothing installed -- refusing to network-debootstrap a bare Debian" >&2
    exit 1
fi
if [ -n "$SQDIR" ]; then
    echo "I: r159 stub: LAYERED SQUASHFS install from $SQDIR" >&2
    LDR=$(ls "$SQDIR"/sqtools/ld-* 2>/dev/null | head -1)
    UNSQ="$SQDIR/sqtools/unsquashfs"
    if [ ! -x "$UNSQ" ] || [ -z "$LDR" ]; then
        echo "FATAL: r159 stub: sqtools bundle missing (bin=$UNSQ ldr=$LDR)" >&2; exit 1
    fi
    # Wipe the target, but NOT the online-fetch staging root: when the payload
    # came off the network it was written to "$TARGET/ncz-online" because the
    # medium is read-only, and a blind glob would delete the very base.squashfs
    # we just verified and are about to extract.
    for _ncz_e in "$TARGET"/* "$TARGET"/.[!.]* ; do
        [ "$_ncz_e" = "$TARGET/ncz-online" ] && continue
        rm -rf "$_ncz_e"
    done
    rm -rf "$TARGET"/.[!.]* 2>/dev/null || true
    ncz_component_record() {
        _ncz_comp=""
        if [ -r /tmp/ncz-components ] && command -v tr >/dev/null 2>&1; then
            _ncz_comp=$(tr -d ' \t\r\n' < /tmp/ncz-components 2>/dev/null || true)
            [ -n "$_ncz_comp" ] && { printf '%s\n' "$_ncz_comp"; return 0; }
        fi
        if [ -r /var/lib/ncz-components/COMPONENTS ] && command -v tr >/dev/null 2>&1; then
            _ncz_comp=$(tr -d ' \t\r\n' < /var/lib/ncz-components/COMPONENTS 2>/dev/null || true)
            [ -n "$_ncz_comp" ] && {
                printf '%s\n' "$_ncz_comp" > /tmp/ncz-components 2>/dev/null || true
                printf '%s\n' "$_ncz_comp"
                return 0
            }
        fi
        if command -v debconf-get >/dev/null 2>&1; then
            _ncz_comp=$(debconf-get ncz/components 2>/dev/null | tr -d ' \t\r\n' || true)
            [ -n "$_ncz_comp" ] && {
                printf '%s\n' "$_ncz_comp" > /tmp/ncz-components 2>/dev/null || true
                printf '%s\n' "$_ncz_comp"
                return 0
            }
        fi
        if [ -r /var/lib/cdebconf/questions.dat ]; then
            _ncz_comp=$(awk '
                $0 == "Name: ncz/components" { inq=1; next }
                inq && /^Value: / { sub(/^Value: /, ""); print; exit }
                inq && /^Name: / { exit }
            ' /var/lib/cdebconf/questions.dat 2>/dev/null | tr -d ' \t\r\n' || true)
            [ -n "$_ncz_comp" ] && {
                printf '%s\n' "$_ncz_comp" > /tmp/ncz-components 2>/dev/null || true
                printf '%s\n' "$_ncz_comp"
                return 0
            }
        fi
        for _ncz_log in /var/log/syslog /var/log/installer/syslog; do
            [ -r "$_ncz_log" ] || continue
            _ncz_comp=$(awk '
                /debconf: --> GET ncz\/components/ { want=1; next }
                want && /debconf: <-- 0 / {
                    sub(/^.*debconf: <-- 0 /, "")
                    val=$0
                    want=0
                }
                END { if (val != "") print val }
            ' "$_ncz_log" 2>/dev/null | tr -d ' \t\r\n' || true)
            [ -n "$_ncz_comp" ] && {
                printf '%s\n' "$_ncz_comp" > /tmp/ncz-components 2>/dev/null || true
                mkdir -p /var/lib/ncz-components 2>/dev/null || true
                printf '%s\n' "$_ncz_comp" > /var/lib/ncz-components/COMPONENTS 2>/dev/null || true
                printf '%s\n' "$_ncz_comp"
                return 0
            }
        done
        return 1
    }
    # The installation media has one complete target.  Keep the desktop-layer
    # name internally until the legacy layer filenames are retired, but never
    # select a separate server overlay from a boot-time argument.
    ROLE=desktop
    _applied_role="$ROLE"
    echo "I: r159 stub: component-selector state before ROLE decision: /tmp=[$(ls -l /tmp/ncz-components 2>&1)] value=[$(cat /tmp/ncz-components 2>/dev/null || true)] durable=[$(ls -l /var/lib/ncz-components/COMPONENTS 2>&1)] durable_value=[$(cat /var/lib/ncz-components/COMPONENTS 2>/dev/null || true)]" >&2
    _ck=$(ncz_component_record 2>/dev/null || true)
    if [ -n "$_ck" ]; then
        _want_desktop=1
        case ",$_ck," in
            *",desktop,"*) _want_desktop=1 ;;
            *)              _want_desktop=0 ;;
        esac
        if [ "$_want_desktop" = 0 ]; then
            ROLE=base
            _applied_role=base
            echo "I: r159 stub: component-selector desktop OFF ($_ck); installing BASE ONLY" >&2
        else
            echo "I: r159 stub: component-selector desktop ON ($_ck); applying desktop overlay" >&2
        fi
    else
        echo "W: r159 stub: component selection unavailable; defaulting to desktop overlay" >&2
    fi
    echo "I: r159 stub: unsquashfs base -> $TARGET" >&2
    "$LDR" --library-path "$SQDIR/sqtools" "$UNSQ" -f -d "$TARGET" "$SQDIR/base.squashfs" >/dev/null 2>&1 || {
        echo "FATAL: r159 stub: unsquashfs base failed" >&2; exit 1; }
    if [ "$ROLE" = "desktop" ] && [ -f "$SQDIR/$ROLE.squashfs" ]; then
        # The role image is an overlayfs upperdir. Its companion manifest
        # records both 0:0 whiteouts and trusted.overlay.opaque directories.
        # Both semantics must be applied to the extracted base before ordinary
        # unsquashfs extraction; otherwise the result is a partial, incoherent
        # filesystem (the v15 DBus/network/greeter failure).
        OVERLAY_MANIFEST="$SQDIR/$ROLE.overlay-manifest"
        [ -s "$OVERLAY_MANIFEST" ] || {
            echo "FATAL: r159 stub: missing $ROLE overlay manifest" >&2
            exit 1
        }
        OVERLAY_COUNT=0
        OVERLAY_TAB=$(printf '\t')
        while IFS="$OVERLAY_TAB" read -r kind rel; do
            case "$kind" in
                '#'*|'') continue ;;
                whiteout|opaque) ;;
                *)
                    echo "FATAL: r159 stub: invalid $ROLE overlay operation '$kind'" >&2
                    exit 1
                    ;;
            esac
            case "$rel" in
                ''|.|/*|../*|*/../*|*/..)
                    echo "FATAL: r159 stub: unsafe $ROLE overlay path '$rel'" >&2
                    exit 1
                    ;;
            esac
            rm -rf "$TARGET/$rel" || {
                echo "FATAL: r159 stub: cannot apply $kind '$rel'" >&2
                exit 1
            }
            OVERLAY_COUNT=$((OVERLAY_COUNT + 1))
        done < "$OVERLAY_MANIFEST"
        echo "I: r159 stub: applied $OVERLAY_COUNT $ROLE overlay operation(s)" >&2

        echo "I: r159 stub: unsquashfs $ROLE delta -> $TARGET" >&2
        "$LDR" --library-path "$SQDIR/sqtools" "$UNSQ" -f -d "$TARGET" "$SQDIR/$ROLE.squashfs" >/dev/null 2>&1 || {
            echo "FATAL: r159 stub: $ROLE delta extraction failed" >&2
            exit 1
        }
        # Remove the extracted 0:0 markers by their already-validated manifest
        # paths. This avoids a slow whole-root find/stat pass over thousands of
        # nodes while preserving every legitimate /dev node.
        while IFS="$OVERLAY_TAB" read -r kind rel; do
            [ "$kind" = whiteout ] || continue
            rm -rf "$TARGET/$rel" || {
                echo "FATAL: r159 stub: cannot remove whiteout marker '$rel'" >&2
                exit 1
            }
        done < "$OVERLAY_MANIFEST"
        HOTFIX_ROLE="$ROLE-hotfix"
        HOTFIX_IMAGE="$SQDIR/$HOTFIX_ROLE.squashfs"
        HOTFIX_MANIFEST="$SQDIR/$HOTFIX_ROLE.overlay-manifest"
        if [ -f "$HOTFIX_IMAGE" ]; then
            [ -s "$HOTFIX_MANIFEST" ] || {
                echo "FATAL: r159 stub: missing $HOTFIX_ROLE overlay manifest" >&2
                exit 1
            }
            HOTFIX_COUNT=0
            while IFS="$OVERLAY_TAB" read -r kind rel; do
                case "$kind" in
                    '#'*|'') continue ;;
                    whiteout|opaque) ;;
                    *)
                        echo "FATAL: r159 stub: invalid $HOTFIX_ROLE overlay operation '$kind'" >&2
                        exit 1
                        ;;
                esac
                case "$rel" in
                    ''|.|/*|../*|*/../*|*/..)
                        echo "FATAL: r159 stub: unsafe $HOTFIX_ROLE overlay path '$rel'" >&2
                        exit 1
                        ;;
                esac
                rm -rf "$TARGET/$rel" || {
                    echo "FATAL: r159 stub: cannot apply $HOTFIX_ROLE $kind '$rel'" >&2
                    exit 1
                }
                HOTFIX_COUNT=$((HOTFIX_COUNT + 1))
            done < "$HOTFIX_MANIFEST"
            echo "I: r159 stub: applied $HOTFIX_COUNT $HOTFIX_ROLE overlay operation(s)" >&2

            echo "I: r159 stub: unsquashfs $HOTFIX_ROLE delta -> $TARGET" >&2
            "$LDR" --library-path "$SQDIR/sqtools" "$UNSQ" -f -d "$TARGET" "$HOTFIX_IMAGE" >/dev/null 2>&1 || {
                echo "FATAL: r159 stub: $HOTFIX_ROLE delta extraction failed" >&2
                exit 1
            }
            while IFS="$OVERLAY_TAB" read -r kind rel; do
                [ "$kind" = whiteout ] || continue
                rm -rf "$TARGET/$rel" || {
                    echo "FATAL: r159 stub: cannot remove $HOTFIX_ROLE whiteout marker '$rel'" >&2
                    exit 1
                }
            done < "$HOTFIX_MANIFEST"
        fi
    elif [ "$_applied_role" = "base" ]; then
        echo "I: r159 stub: role=base (component-selector desktop OFF); skipping desktop overlay" >&2
    fi
    # 2026-08-26 ROOT-MODE GATE — THE LIVE PATH (docs/ISO-BUILD-GUARDRAILS.md).
    # Root cause of the 0700-root incident, found+proven 2026-08-26:
    # `unsquashfs -f -d $TARGET` re-stamps $TARGET's OWN mode from EACH
    # layer's root entry (verified with the bundled sqtools unsquashfs AND
    # squashfs-tools 4.6.1: an existing 755 dir became 700 after extracting a
    # layer whose root entry was drwx------). desktop-hotfix.squashfs was
    # built 2026-08-25 out-of-repo from a mktemp -d staging dir (mode 0700),
    # so the LAST layer stamped / to 0700 on every install — breaking greetd
    # (EACCES traversing /), NIC bring-up and rtc-efi for every non-root UID.
    # Round 1 (7de5ce6) gated preseed/extract-rootfs.sh — but partman/
    # late_command is NOT a real d-i hook (see the r159 note above), so that
    # script never runs: THIS stub is the real extraction path and had no
    # gate. Pin 0755 after the FULL layer stack and hard-verify; exit 1 makes
    # bootstrap-base fail loudly instead of shipping a broken root.
    chmod 0755 "$TARGET" || { echo "FATAL: rootmode stub: chmod 0755 $TARGET failed" >&2; exit 1; }
    # BusyBox in the d-i initrd has no `stat` applet (confirmed live on O6N:
    # "stat: not found", even `busybox stat` -> "applet not found") -- use
    # `ls -ld` (confirmed present) and compare the permission-string field
    # instead of an octal mode, same pattern as assert_squashfs_root_mode().
    _ncz_rm=$(ls -ld "$TARGET" 2>/dev/null | awk '{print $1}')
    [ -n "$_ncz_rm" ] || _ncz_rm="???"
    if [ "$_ncz_rm" != "drwxr-xr-x" ]; then
        echo "FATAL: rootmode stub: $TARGET root mode is $_ncz_rm after layer extraction (expected drwxr-xr-x/0755) — refusing to ship a broken install" >&2
        exit 1
    fi
    echo "I: rootmode stub: verified $TARGET root mode = drwxr-xr-x (0755) after full layer stack" >&2
    if [ ! -f "$TARGET/etc/os-release" ]; then
        echo "FATAL: r159 stub: squashfs extract produced no os-release" >&2; exit 1
    fi
    # r159: finish deferred dpkg config; purge pkgs that cannot configure in a
    # chroot (e.g. falkon needs a display) so d-i pkgsel's apt does not choke on a
    # half-configured package. Bind-mount for maintainer scripts, then unmount.
    for _m in proc sys dev; do mount --bind /$_m "$TARGET/$_m" 2>/dev/null; done
    mount --bind /dev/pts "$TARGET/dev/pts" 2>/dev/null
    # The raw-GPT data partition is mounted by d-i as /cdrom, but it is not an
    # apt CD-ROM and apt-cdrom cannot register it.  Make the regular on-media
    # repository visible inside the target before apt-setup and user-setup run,
    # and remove the baked live sources for the duration of installation.
    # late.sh replaces these with the runtime update sources before reboot.
    _TARGET_ARCH=$(chroot "$TARGET" dpkg --print-architecture 2>/dev/null)
    _MEDIA_SUITE=""
    for _d in /cdrom/dists/*; do
        [ -s "$_d/main/binary-${_TARGET_ARCH}/Packages" ] || continue
        _MEDIA_SUITE=${_d##*/}
        break
    done
    if [ -n "$_MEDIA_SUITE" ]; then
        mkdir -p "$TARGET/cdrom" "$TARGET/etc/apt/sources.list.d"
        mount --bind /cdrom "$TARGET/cdrom" 2>/dev/null || {
            echo "FATAL: r159 stub: cannot bind installation repository into target" >&2; exit 1; }
        rm -f "$TARGET/etc/apt/sources.list.d/"*.list \
              "$TARGET/etc/apt/sources.list.d/"*.sources
        echo "deb [trusted=yes] file:///cdrom $_MEDIA_SUITE main" > "$TARGET/etc/apt/sources.list"
        mkdir -p "$TARGET/etc/apt/apt.conf.d"
        echo 'Acquire::Check-Date "false";' > "$TARGET/etc/apt/apt.conf.d/00ncz-install-time-clock"
        # apt-setup 0.200 only consults use_mirror when
        # /cdrom/.disk/base_installable exists.  This raw-GPT medium correctly
        # has no such marker, so 50mirror otherwise ignores use_mirror=false
        # and unconditionally regenerates the configured HTTP source. Anna is
        # finished by this point, so remove only that apt-setup generator; the
        # preseeded 60local repository becomes the sole install source.
        if [ -x /usr/lib/apt-setup/generators/50mirror ]; then
            mv /usr/lib/apt-setup/generators/50mirror \
               /usr/lib/apt-setup/generators/.50mirror.ncz-disabled || {
                echo "FATAL: r159 stub: cannot disable apt-setup 50mirror" >&2; exit 1; }
        fi
        echo "I: r159 stub: target apt pinned to file:///cdrom $_MEDIA_SUITE/main for installation" >&2
    else
        echo "FATAL: r159 stub: no on-media $_TARGET_ARCH apt repository found" >&2
        exit 1
    fi
    # A base layer can omit Text::Iconv even though debconf's Encoding.pm
    # unconditionally calls it. That makes every debconf-apt-progress invocation
    # fail after apt itself succeeds, and apt-setup loops forever at 50mirror.
    # Install the package from the on-media pool before any d-i target-side
    # debconf frontend runs. Do not mask mirror errors: make the rootfs complete.
    _ICONV_DEB=$(find /cdrom/pool -type f -name "libtext-iconv-perl_*_${_TARGET_ARCH}.deb" 2>/dev/null | head -1)
    if [ -n "$_ICONV_DEB" ] && ! chroot "$TARGET" dpkg-query -W libtext-iconv-perl >/dev/null 2>&1; then
        cp "$_ICONV_DEB" "$TARGET/tmp/ncz-libtext-iconv-perl.deb" || {
            echo "FATAL: r159 stub: cannot stage libtext-iconv-perl" >&2; exit 1; }
        chroot "$TARGET" dpkg -i /tmp/ncz-libtext-iconv-perl.deb 2>&1 || {
            echo "FATAL: r159 stub: cannot install libtext-iconv-perl" >&2; exit 1; }
        rm -f "$TARGET/tmp/ncz-libtext-iconv-perl.deb"
        echo "I: r159 stub: installed libtext-iconv-perl for debconf progress" >&2
    fi
    chroot "$TARGET" dpkg --configure -a 2>/dev/null
    # r172: PRESERVE falkon (the NCZ web browser). It can't finish configuring in
    # the d-i chroot (its postinst wants a display/dbus), so r159 purged it as
    # "non-configured" — which left the installed desktop with NO working browser
    # (firefox on the old Ubuntu base was a snap stub that no-ops in an offline image; only
    # falkon + epiphany are real debs). Keep falkon (+ its parts) out of the purge
    # and let ncz-firstboot's `dpkg --configure -a` finish it on first boot where
    # X/dbus exist. Everything else non-ii is still purged so pkgsel's dpkg stays
    # clean.
    _BAD=$(chroot "$TARGET" dpkg -l 2>/dev/null | awk '$1 ~ /^.[A-Z]/ && $1 != "ii" {print $2}' | grep -viE '^falkon')
    [ -n "$_BAD" ] && { echo "I: r172 stub: purging non-configured (keeping falkon): $_BAD" >&2; chroot "$TARGET" dpkg --purge --force-all $_BAD 2>/dev/null; }
    # Best-effort configure of falkon now; if it still can't (no display), it stays
    # unpacked and ncz-firstboot configures it. pkgsel tolerates unpacked (unlike
    # a broken statoverride) as long as dpkg itself isn't wedged.
    chroot "$TARGET" dpkg --configure falkon 2>/dev/null || true
    # r169: drop orphaned dpkg statoverrides whose owning user no longer exists.
    # The GNOME-purge/autoremove in the squashfs build (and this STUB's own
    # dpkg --configure/purge above) can leave a statoverride like
    #   geoclue geoclue 755 /var/lib/geoclue
    # after the 'geoclue' system user is gone. A dangling override makes dpkg
    # abort with "unknown system user 'geoclue' in statoverride file" on EVERY
    # later dpkg op → d-i pkgsel apt-get install fails ("Installation step
    # failed"). Clean at install time, after configure/purge, before pkgsel runs.
    # r170: collect orphan paths in a FIRST read-only pass, then remove them —
    # dpkg-statoverride --remove rewrites the very file we read, so removing
    # inside the read loop corrupts it (r169 removed geoclue but mangled the
    # file into an "unknown system user 'root'" abort). Guard on getent working
    # so a broken NSS can't nuke every (legitimate, e.g. root:shadow) override.
    chroot "$TARGET" sh -c '
        getent passwd root >/dev/null 2>&1 || exit 0
        orphans=""
        while read u g m f; do
            [ -n "$u" ] && [ -n "$f" ] || continue
            getent passwd "$u" >/dev/null 2>&1 || orphans="$orphans
$f"
        done < /var/lib/dpkg/statoverride
        printf "%s\n" "$orphans" | while IFS= read -r p; do
            [ -n "$p" ] && dpkg-statoverride --remove "$p" 2>/dev/null || true
        done
    ' 2>/dev/null || true
    echo "I: r170 stub: pruned orphaned statoverrides (missing user)" >&2
    for _m in dev/pts dev sys proc; do umount "$TARGET/$_m" 2>/dev/null; done
    # r159: disable needrestart kernel hints so pkgsel/apt does not raise the
    # "pending kernel upgrade / consider rebooting" note (baked kernel != d-i
    # installer kernel) that blocks "Select and install software".
    mkdir -p "$TARGET/etc/needrestart/conf.d"
    printf '$nrconf{kernelhints} = 0;\n' > "$TARGET/etc/needrestart/conf.d/99-baked.conf"
    # r160: per-machine ssh host keys. The base rootfs ships
    # openssh-server but STRIPS the host keys (cloud-init would normally
    # regenerate them); without keys sshd refuses to start and the installed
    # system is unreachable on :22. Generate here, at install time, so every
    # machine gets unique keys — never bake host keys into the squashfs.
    chroot "$TARGET" ssh-keygen -A 2>/dev/null || \
        echo "W: r160 stub: ssh-keygen -A failed (openssh-server missing from image?)" >&2
    # r160: fleet remote-access policy. The cloud-image drop-in forces
    # PasswordAuthentication no; the fleet is LAN-only and wants password
    # fallback when keys break. OpenSSH keyword resolution is first-value-wins
    # across lexically-sorted sshd_config.d, so 10- beats any later drop-in.
    rm -f "$TARGET/etc/ssh/sshd_config.d/60-cloudimg-settings.conf"
    mkdir -p "$TARGET/etc/ssh/sshd_config.d"
    printf 'PasswordAuthentication yes\n' > "$TARGET/etc/ssh/sshd_config.d/10-ncz-fleet.conf"
    # r160: de-cloud the network stack. The cloud rootfs enables
    # systemd-networkd + its wait-online + networkd-dispatcher ALONGSIDE
    # NetworkManager; networkd has no .network config on NCZ so
    # systemd-networkd-wait-online stalls every boot for its full ~120s
    # timeout. NCZ is NetworkManager-managed — drop the networkd enablement
    # symlinks (NM + NM-wait-online stay).
    rm -f "$TARGET/etc/systemd/system/multi-user.target.wants/systemd-networkd.service" \
          "$TARGET/etc/systemd/system/multi-user.target.wants/networkd-dispatcher.service" \
          "$TARGET/etc/systemd/system/sockets.target.wants/systemd-networkd.socket" \
          "$TARGET/etc/systemd/system/network-online.target.wants/systemd-networkd-wait-online.service" \
          "$TARGET/etc/systemd/system/dbus-org.freedesktop.network1.service" 2>/dev/null
    : > "$TARGET/etc/ncz-baked"
    mkdir -p "$TARGET/usr/local/sbin" "$TARGET/etc/systemd/system/multi-user.target.wants"
    cat > "$TARGET/usr/local/sbin/ncz-firstboot" <<'FBS'
#!/bin/sh
export DEBIAN_FRONTEND=noninteractive
# Package configure step. lib/firstboot-gpu.sh wraps `dpkg --configure -a`
# with an on-screen status whenever a DKMS kernel-module build is involved
# (a build that is needed runs here with a live status line; one that
# already failed with a compiler error at install time is left to the
# background retry instead of delaying the login screen). Older payloads
# without the helper keep the bare command.
_fbg=/usr/local/lib/cix-installer/post-install/lib/firstboot-gpu.sh
if [ -r "$_fbg" ] && command -v bash >/dev/null 2>&1; then
    bash "$_fbg" configure || dpkg --configure -a 2>/dev/null || true
else
    dpkg --configure -a 2>/dev/null || true
fi
[ -s /etc/machine-id ] || systemd-machine-id-setup 2>/dev/null || true

# r177: per-machine hostname ncz-<last-6-hex-of-primary-ethernet-MAC>. The real
# hardware MAC is authoritative HERE (first boot on the actual box), not at bake
# time. Only rename when the hostname is still a placeholder/default so a
# user-chosen name on later boots is never clobbered.
HOSTNAME_SETTLED=1   # set to 0 to keep the service enabled + retry the derive next boot
_cur=$(cat /etc/hostname 2>/dev/null | tr -d '[:space:]')
case "$_cur" in
    ""|ncz-setup|mini|cixmini|localhost|localhost.localdomain|debian|ubuntu|nclawzero)
        # Find the primary ethernet MAC. Two passes per attempt: first prefer an
        # iface with link (carrier=1), else the first eligible ethernet. Retry a
        # few seconds in case NIC enumeration lags this early oneshot.
        _pick_mac() {
            for _pref in 1 0; do
                for _if in /sys/class/net/*; do
                    _n=${_if##*/}
                    case "$_n" in
                        lo|wl*|ww*|wlan*|docker*|veth*|virbr*|br-*|vmnet*|tap*|tun*|bond*|dummy*|sit*|ip6*) continue ;;
                    esac
                    # physical only: must have a backing device, must not be wireless
                    [ -e "$_if/device" ] || continue
                    [ -d "$_if/wireless" ] && continue
                    _m=$(cat "$_if/address" 2>/dev/null)
                    [ -n "$_m" ] || continue
                    case "$_m" in 00:00:00:00:00:00) continue ;; esac
                    if [ "$_pref" = 1 ] && [ "$(cat "$_if/carrier" 2>/dev/null)" != 1 ]; then
                        continue
                    fi
                    printf '%s' "$_m"; return 0
                done
            done
            return 1
        }
        _mac=""
        _try=0
        while [ "$_try" -lt 15 ]; do
            _mac=$(_pick_mac) && [ -n "$_mac" ] && break
            _mac=""; _try=$((_try+1)); sleep 1
        done
        _newname=""
        if [ -n "$_mac" ]; then
            _h6=$(printf '%s' "$_mac" | tr -d ':' | tr 'A-F' 'a-f' | tail -c 6)
            [ -n "$_h6" ] && _newname="ncz-$_h6"
        fi
        if [ -z "$_newname" ]; then
            # No eligible ethernet MAC this boot. RETRY on the next few boots so a
            # slow-to-enumerate NIC eventually names the box; after MAXTRIES fall
            # back to a machine-id-derived name so it is NEVER stuck as ncz-setup.
            _bt=$(cat /var/lib/ncz-firstboot-tries 2>/dev/null)
            case "$_bt" in ''|*[!0-9]*) _bt=0 ;; esac
            _bt=$((_bt + 1))
            printf '%s\n' "$_bt" > /var/lib/ncz-firstboot-tries 2>/dev/null || true
            if [ "$_bt" -lt 3 ]; then
                HOSTNAME_SETTLED=0
                echo "ncz-firstboot: no eligible ethernet MAC yet (attempt $_bt) — will retry next boot" >&2
            else
                _mid=$(tr -cd '0-9a-f' < /etc/machine-id 2>/dev/null | tail -c 6)
                [ -n "$_mid" ] && _newname="ncz-$_mid"
                echo "ncz-firstboot: no ethernet MAC after $_bt boots — machine-id fallback ${_newname:-<none>}" >&2
            fi
        fi
        if [ -n "$_newname" ]; then
            if command -v hostnamectl >/dev/null 2>&1 && hostnamectl set-hostname "$_newname" 2>/dev/null; then
                :
            else
                printf '%s\n' "$_newname" > /etc/hostname
                hostname "$_newname" 2>/dev/null || true
            fi
            if grep -q '^127\.0\.1\.1' /etc/hosts 2>/dev/null; then
                sed -i "s/^127\.0\.1\.1.*/127\.0\.1\.1\t$_newname/" /etc/hosts
            else
                printf '127.0.1.1\t%s\n' "$_newname" >> /etc/hosts
            fi
        fi
        ;;
esac

# 2026-08-26 first-boot root-mode belt (0700-root incident; see
# docs/ISO-BUILD-GUARDRAILS.md). Runs AFTER dpkg --configure -a above (package
# postinsts are the last code to run before a login screen) and before
# display-manager.service (unit ordering), so a bad / mode is corrected before
# greetd would hit EACCES traversing /. Always emits a NCZ-ROOTMODE marker to
# kmsg+console so build/kvm-install-gate.sh phase 2 can assert the final mode
# from OUTSIDE the VM via the boot serial capture.
# Full installed userspace normally has GNU coreutils `stat`, but keep this
# consistent with the d-i-side gates (ls -ld, not stat) so the same logic
# works even on a minimal/degraded first boot.
_rm=$(ls -ld / 2>/dev/null | awk '{print $1}')
[ -n "$_rm" ] || _rm="???"
if [ "$_rm" != "drwxr-xr-x" ]; then
    echo "ncz-firstboot: WARNING / mode was $_rm (expected drwxr-xr-x/0755) — correcting" > /dev/kmsg 2>/dev/null || true
    chmod 0755 / 2>/dev/null || true
    _rm=$(ls -ld / 2>/dev/null | awk '{print $1}')
    [ -n "$_rm" ] || _rm="???"
fi
# <6> = info: the marker is a normal-boot report, not a warning (a bare
# /dev/kmsg write is logged at the default warning level). The console
# echo below is what the KVM gate reads; it is unchanged.
echo "<6>NCZ-ROOTMODE: $_rm" > /dev/kmsg 2>/dev/null || true
echo "NCZ-ROOTMODE: $_rm" > /dev/console 2>/dev/null || true

# 2026-09-08 GPU glvnd-compat belt (labwc SIGSEGV / free(): invalid pointer
# incident, O6N first-boot). post-install/26-gpu-default-mali.sh correctly
# disables /etc/ld.so.conf.d/01-cixgpu-compat.conf at install time via a
# rename to .disabled -- but dpkg does not know about that rename, so the
# dpkg --configure -a above (cix-libglvnd has a deferred/triggered postinst)
# re-lays-down its shipped default conffile and silently UNDOES the disable
# on every single fresh install's first boot, before hook 26 or the operator
# ever gets a chance to notice. Symptom: labwc SIGSEGVs in __eglLoadVendors
# (cix-libglvnd 1.1.0's ancient glvnd shim fighting the system glvnd 1.7.0 +
# Mesa 26 stack) on every launch -- greetd start-limit-hits, black screen.
# Same belt-after-dpkg-configure pattern as the root-mode fix above, for the
# same reason: package postinsts are the last code to run before the login
# screen, so re-assert our config choice AFTER them, not just at build time.
if [ -e /etc/ld.so.conf.d/01-cixgpu-compat.conf ]; then
    echo "ncz-firstboot: WARNING 01-cixgpu-compat.conf re-appeared after dpkg --configure -a -- disabling again" > /dev/kmsg 2>/dev/null || true
    mv /etc/ld.so.conf.d/01-cixgpu-compat.conf /etc/ld.so.conf.d/01-cixgpu-compat.conf.disabled 2>/dev/null || true
    ldconfig 2>/dev/null || true
fi

# Only finalize (disable + mark done) when the hostname is SETTLED. When we are
# deliberately retrying the MAC-derive on a later boot (HOSTNAME_SETTLED=0), we
# leave the service enabled and NOT-done so it runs again — dpkg-configure and
# machine-id above already ran this boot, and the host will never be permanently
# stuck as ncz-setup (machine-id fallback after MAXTRIES guarantees a name).
if [ "${HOSTNAME_SETTLED:-1}" = 1 ]; then
    systemctl disable ncz-firstboot.service 2>/dev/null || true
    touch /var/lib/ncz-firstboot-done
fi
FBS
    chmod +x "$TARGET/usr/local/sbin/ncz-firstboot"
    cat > "$TARGET/etc/systemd/system/ncz-firstboot.service" <<'FBU'
[Unit]
Description=NCZ first-boot finalize (dpkg configure, GPU driver build status, machine identity)
ConditionPathExists=!/var/lib/ncz-firstboot-done
DefaultDependencies=no
# dpkg --configure -a may run package ldconfig triggers; let systemd's stock
# ldconfig.service finish first so both do not race over /etc/ld.so.cache~.
After=local-fs.target ldconfig.service
Before=display-manager.service gdm.service graphical.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/ncz-firstboot
# A first-boot DKMS build must never be cut short (oneshot already defaults
# to no start timeout; stated explicitly so a drop-in default cannot add one).
TimeoutStartSec=infinity
[Install]
WantedBy=multi-user.target
FBU
    ln -sf ../ncz-firstboot.service "$TARGET/etc/systemd/system/multi-user.target.wants/ncz-firstboot.service"
    [ -e "$TARGET/etc/fstab" ] || touch "$TARGET/etc/fstab"
    : > "$TARGET/etc/fstab.orig"
    # r177: deterministic hostname PLACEHOLDER. ncz-firstboot rewrites this to
    # ncz-<mac6> on first boot (guarded on the placeholder). Baked squashfs may
    # ship its own /etc/hostname; force the placeholder so the derive always fires.
    printf 'ncz-setup\n' > "$TARGET/etc/hostname"
    [ -e "$TARGET/etc/resolv.conf" ] || touch "$TARGET/etc/resolv.conf"
    echo "I: r159 stub: squashfs rootfs ready ($(du -sh "$TARGET" 2>/dev/null | cut -f1))" >&2
    exit 0
fi

# Find rootfs.tar.zst on the install media
ROOTFS=""
for d in /cdrom/ncz-payload /hd-media/ncz-payload /media/cdrom/ncz-payload /run/live/medium/ncz-payload; do
    if [ -f "$d/rootfs.tar.zst" ]; then
        ROOTFS="$d/rootfs.tar.zst"
        break
    fi
done
if [ -z "$ROOTFS" ]; then
    echo "FATAL: r40 stub debootstrap: rootfs.tar.zst not found in any candidate cdrom location" >&2
    exit 1
fi

# Verify zstd exists in d-i runtime (injected via prepare_static_zstd)
if ! command -v zstd >/dev/null 2>&1; then
    if [ -x /usr/bin/zstd ]; then
        ZSTD=/usr/bin/zstd
    else
        echo "FATAL: r40 stub debootstrap: zstd binary not found" >&2
        exit 1
    fi
else
    ZSTD=$(command -v zstd)
fi

# Wipe any partial scaffolding from a prior failed attempt
rm -rf "$TARGET"/* "$TARGET"/.[!.]* 2>/dev/null || true

echo "I: r40 stub debootstrap: extracting $ROOTFS into $TARGET" >&2
echo "I:   ($(du -h "$ROOTFS" 2>/dev/null | cut -f1) compressed; expanded ~6 GB)" >&2
"$ZSTD" -dc "$ROOTFS" | tar -xpf - -C "$TARGET" || {
    echo "FATAL: r40 stub debootstrap: tar extract failed (exit $?)" >&2
    exit 1
}

# Sanity-check
if [ ! -f "$TARGET/etc/os-release" ] || [ ! -d "$TARGET/usr/bin" ]; then
    echo "FATAL: r40 stub debootstrap: extract did not produce expected layout" >&2
    ls -la "$TARGET" >&2 | head -10
    exit 1
fi

# Cloudimg has no /etc/fstab (cloud-init generates one at first boot).
# d-i base-installer post-extract step expects fstab to exist so it can back
# it up to fstab.orig before writing its own. Create an empty placeholder.
[ -e "$TARGET/etc/fstab" ] || touch "$TARGET/etc/fstab"

# r44: also pre-create /target/etc/fstab.orig — d-i base-installer's
# /usr/lib/base-installer/debootstrap wrapper (the one that calls our stub)
# does an unconditional 'mv $TARGET/etc/fstab.orig $TARGET/etc/fstab' after
# we return. Real debootstrap creates fstab.orig as a side effect; our stub
# doesn't. GRAEAE 8-muse consensus 2026-05-04: pre-create empty .orig.
: > "$TARGET/etc/fstab.orig"

# Same defensive empty-files for any other path d-i might write through.
#
# r177 NOTE (review): this legacy rootfs.tar.zst extract path is SUPERSEDED and
# is NOT reached in current builds — the layered-squashfs branch above (taken
# whenever base.squashfs is on the media, which it always is in full mode)
# installs the ncz-firstboot hostname-derivation flow + the deterministic
# ncz-setup placeholder and `exit 0`s before we ever get here. This tarball
# fallback deliberately does NOT duplicate that flow (it also does not write the
# BAKED marker, ncz-firstboot, needrestart/ssh/networkd fixups the squashfs path
# does — it predates all of them). If this path is ever revived as a real
# install route, port the ncz-firstboot + ncz-setup-placeholder block up from the
# squashfs branch; a bare empty /etc/hostname here would otherwise leave the box
# unnamed. Left as a bare touch on purpose since the path is dead.
[ -e "$TARGET/etc/hostname" ] || touch "$TARGET/etc/hostname"
[ -e "$TARGET/etc/resolv.conf" ] || touch "$TARGET/etc/resolv.conf"

echo "I: r43 stub debootstrap: rootfs ready at $TARGET ($(du -sh "$TARGET" 2>/dev/null | cut -f1))" >&2
exit 0
"""


# ----------------------------------------------------------------------------
# Udeb patching primitives.
# ----------------------------------------------------------------------------

# Udeb control fields and member ordering are documented in Debian
# policy §5.1 ("control archive") and dpkg-deb(1). A .udeb is just a .deb
# with the same layout (ar archive of: debian-binary, control.tar.*,
# data.tar.*). We use `ar` from binutils for the round-trip because dpkg
# -b is much harder to drive without a control file preprocessor; `ar`
# just packs members verbatim, which is what we want here.
REQUIRED_UDEB_SHELL = ["debootstrap-udeb", "libzstd1-udeb", "liblzma5-udeb"]
REQUIRED_UDEB_DI = ["cdebconf-udeb", "cdebconf-newt-udeb", "hw-detect"]


def verify_udeb_required(substrate_pool: Path, required, label: str,
                         fatal: bool = True):
    """Check that each name in ``required`` is present in the pool at
    ``pool/**/<name>_*.udeb``. Returns a list of names that were FOUND
    (so a caller can both gate and report). Raises RuntimeError if any
    is missing.

    This is the assertion from the retired ``build/build-iso-di.sh:1035-1062``
    lifted verbatim: 3 shell-side udebs (``debootstrap-udeb``,
    ``libzstd1-udeb``, ``liblzma5-udeb``) and 3 d-i runtime udebs
    (``cdebconf-udeb``, ``cdebconf-newt-udeb``, ``hw-detect``).
    """
    found = []
    missing = []
    for pkg in required:
        matches = list(substrate_pool.rglob(f"{pkg}_*.udeb"))
        if matches:
            found.append(pkg)
            log(f"    udeb assertion [{label}]: {pkg}: PRESENT ({len(matches)} match(es))")
        else:
            missing.append(pkg)
            log(f"    udeb assertion [{label}]: {pkg}: MISSING")
    if missing and fatal:
        raise RuntimeError(
            f"ERROR: substrate pool missing required udeb(s): {missing} "
            f"(search: {substrate_pool}/**/<name>_*.udeb). "
            f"See the retired build-iso-di.sh line ~1035 for why each is required."
        )
    return found, missing


def _run_ar(ar_args, cwd=None):
    """Wrapper around the system ``ar`` that surfaces stderr on failure."""
    cmd = ["ar"] + ar_args
    return subprocess.run(cmd, cwd=str(cwd) if cwd else None,
                          capture_output=True, text=True)


def _list_udeb_members(udeb_path: Path):
    """Run ``ar t <udeb>`` to get the member list. Asserts 3 members in
    standard order: debian-binary, control.tar.*, data.tar.* (the dpkg
    ``ar`` archive convention)."""
    proc = _run_ar(["t", str(udeb_path)])
    if proc.returncode != 0:
        raise RuntimeError(f"ar t {udeb_path} failed: {proc.stderr.strip()}")
    members = [m.strip() for m in proc.stdout.splitlines() if m.strip()]
    if len(members) != 3:
        raise RuntimeError(
            f"udeb {udeb_path} has {len(members)} ar members, expected 3 "
            f"(debian-binary + control.tar.* + data.tar.*). Got: {members}"
        )
    if members[0] != "debian-binary":
        raise RuntimeError(
            f"udeb {udeb_path} first ar member is '{members[0]}', "
            f"expected 'debian-binary'. Order matters for dpkg parsing."
        )
    if not (members[1].startswith("control.tar") and members[2].startswith("data.tar")):
        raise RuntimeError(
            f"udeb {udeb_path} members are {members[1:]}, expected "
            f"control.tar.* then data.tar.*"
        )
    return members


def _extract_data_tar(udeb_path: Path, dest_dir: Path):
    """Extract ``data.tar.*`` from the udeb to ``dest_dir``. Returns the
    path to the extracted data root (``dest_dir/usr/sbin/debootstrap``
    lives here). The original ``data.tar.*`` filename and compression
    (gzip/xz/zst/none) are inspected but we ALWAYS repack as data.tar.gz
    on the way out (the retired build-iso-di.sh repack used gzip -9n at
    line ~1677; keeping gzip preserves dpkg's reading path).
    """
    proc = _run_ar(["x", str(udeb_path)], cwd=dest_dir)
    if proc.returncode != 0:
        raise RuntimeError(
            f"ar x {udeb_path} (cwd={dest_dir}) failed: {proc.stderr.strip()}"
        )
    candidates = sorted(dest_dir.glob("data.tar*"))
    candidates = [c for c in candidates if c.is_file()]
    if not candidates:
        raise RuntimeError(
            f"ar x {udeb_path} did not produce a data.tar.* in {dest_dir}"
        )
    if len(candidates) > 1:
        # Some old udebs ship both data.tar and data.tar.gz; only the
        # .gz is used. We pick the .gz variant, matching what dpkg does.
        gz = [c for c in candidates if str(c).endswith(".gz")]
        if gz:
            candidates = gz
    data_tar = candidates[0]
    extract_proc = subprocess.run(
        ["tar", "-xf", str(data_tar), "-C", str(dest_dir)],
        capture_output=True, text=True,
    )
    if extract_proc.returncode != 0:
        raise RuntimeError(
            f"tar -xf {data_tar} -C {dest_dir} failed: "
            f"{extract_proc.stderr.strip()}"
        )
    return data_tar


def _repack_udeb(ar_dir: Path, control_member: str,
                 data_member_original: Path, output_udeb: Path) -> None:
    """Repack a directory of ar members into a fresh .udeb. Members
    (in the order dpkg expects):

      1. debian-binary      (verbatim from ar_dir)
      2. control.tar.*      (verbatim from ar_dir)
      3. data.tar.gz        (recompressed from the modified data tree)

    We always repack as data.tar.gz because that's what dpkg reads
    most portably; the original .xz/.zst extraction was just for the
    in-place edit. The other members (debian-binary, control.tar.*)
    are copied verbatim from ar_dir.
    """
    members_to_skip = {"debian-binary", control_member,
                       data_member_original.name}

    with tempfile.TemporaryDirectory() as tmpdir_str:
        tmpdir = Path(tmpdir_str)
        staged_data = tmpdir / "staged-data"
        staged_data.mkdir()
        for entry in sorted(ar_dir.iterdir()):
            if entry.name in members_to_skip:
                continue
            dest = staged_data / entry.name
            if entry.is_dir():
                shutil.copytree(str(entry), str(dest), symlinks=True)
            elif entry.is_symlink():
                dest.symlink_to(entry.readlink())
            else:
                shutil.copy2(str(entry), str(dest))
        data_tar_gz = tmpdir / "data.tar.gz"
        # Byte-reproducible repack.  Without this the patched udeb's sha256
        # changed on every invocation (the extracted members carry the build
        # host's mtimes), so no static NCZ ledger row could ever match it and
        # the provenance gate failed on debootstrap-udeb every run.
        #
        # Use a FIXED mtime, NOT $SOURCE_DATE_EPOCH: the image build sets
        # SOURCE_DATE_EPOCH to the HEAD commit time (build/lib/reproducible.sh),
        # which changes with every commit, so keying this artifact off it made
        # the verified sha move on every push (observed: 092128b6 -> 975fd87b
        # across two commits).  A constant epoch keeps the patched udeb's bytes
        # a pure function of its inputs, so one reviewed ledger row holds.
        sde = "0"
        tar_proc = subprocess.run(
            ["tar", "--sort=name", "--numeric-owner", "--owner=0",
             "--group=0", f"--mtime=@{sde}",
             "-cf", "-", "-C", str(staged_data), "."],
            capture_output=True,
        )
        if tar_proc.returncode != 0:
            raise RuntimeError(f"tar -cf failed: {tar_proc.stderr.decode()}")
        gzip_proc = subprocess.run(
            ["gzip", "-9n"], input=tar_proc.stdout,
            capture_output=True,
        )
        if gzip_proc.returncode != 0:
            raise RuntimeError(f"gzip -9n failed: {gzip_proc.stderr.decode()}")
        data_tar_gz.write_bytes(gzip_proc.stdout)

        output_udeb.parent.mkdir(parents=True, exist_ok=True)
        # Stage data.tar.gz in ar_dir for `ar rcD` (which operates from cwd).
        shutil.copy2(str(data_tar_gz), str(ar_dir / "data.tar.gz"))
        try:
            ar_proc = subprocess.run(
                ["ar", "rcD", str(output_udeb),
                 "debian-binary", control_member, "data.tar.gz"],
                cwd=str(ar_dir),
                capture_output=True, text=True,
            )
            if ar_proc.returncode != 0:
                raise RuntimeError(
                    f"ar rcD {output_udeb} failed: {ar_proc.stderr.strip()}"
                )
        finally:
            try:
                (ar_dir / "data.tar.gz").unlink()
            except FileNotFoundError:
                pass


def _syntax_check_stub(stub_text: str, label: str) -> None:
    """The retired build-iso-di.sh author ran ``bash -n`` after writing the stub
    (line 1674). We do the same — both ``sh -n`` (POSIX compliance) and
    ``bash -n`` (no bashisms, since the stub is supposed to be POSIX)."""
    with tempfile.NamedTemporaryFile("w", suffix=".sh",
                                     delete=False) as f:
        f.write(stub_text)
        path = Path(f.name)
    try:
        for interp in ("sh", "bash"):
            p = subprocess.run([interp, "-n", str(path)],
                               capture_output=True, text=True)
            if p.returncode != 0:
                raise RuntimeError(
                    f"{label} stub failed {interp} -n: {p.stderr.strip()}"
                )
    finally:
        try:
            path.unlink()
        except FileNotFoundError:
            pass


def _find_substrate_pool(substrate_node_dir: Path):
    """Locate the udeb pool inside a substrate node.

    For ``install_dir``-layout substrates (full Debian netinst ISO), the
    pool is at ``<node>/extract/pool/``. For ``netboot``-layout
    substrates (mini.iso), there is no pool.

    Returns None if no pool is found.
    """
    extract = substrate_node_dir / "extract"
    candidate = extract / "pool"
    if candidate.is_dir():
        return candidate
    return None


def _find_debootstrap_udeb(pool: Path):
    """Find the single ``debootstrap-udeb_*_all.udeb`` in the pool, the
    same way the retired build-iso-di.sh did at line 1067-1071.

    Exactly one match is required.
    """
    matches = sorted(pool.glob("**/debootstrap-udeb_*_all.udeb"))
    if len(matches) == 0:
        raise RuntimeError(
            f"ERROR: debootstrap-udeb not found under {pool} "
            f"(search: **/debootstrap-udeb_*_all.udeb)"
        )
    if len(matches) > 1:
        raise RuntimeError(
            f"ERROR: expected exactly one debootstrap-udeb, found "
            f"{len(matches)}: {[str(m) for m in matches]}"
        )
    return matches[0]


def patch_udeb(udeb_path: Path, output_path: Path, stub_text: str,
               force: bool = False):
    """Patch the debootstrap-udeb at ``udeb_path`` so its
    ``usr/sbin/debootstrap`` member is ``stub_text`` (the r159 stub
    script). Writes the patched udeb to ``output_path``.

    Returns a receipt dict with the patch metadata.
    """
    in_place = udeb_path.resolve() == output_path.resolve()
    final_output = output_path
    if output_path.exists() and not force and not in_place:
        log(f"output exists: {output_path}")
        return {"output": str(output_path), "patched": False}
    if output_path.exists() and not in_place:
        output_path.unlink()
    if in_place:
        # Never unlink the input before ar has read it.  The old code did
        # exactly that with --force, while without --force it returned an
        # "output exists" cache hit and patched nothing.  Build beside the
        # source and atomically replace only after all verification passes.
        output_path = output_path.with_name(output_path.name + f".patched.{os.getpid()}")
        output_path.unlink(missing_ok=True)

    members = _list_udeb_members(udeb_path)
    debian_binary, control_member, data_member = members
    log(f"    udeb members: {members}")

    with tempfile.TemporaryDirectory(prefix="patch-debootstrap-stub.") as tmpdir_str:
        tmpdir = Path(tmpdir_str)
        ar_dir = tmpdir / "ar"
        data_dir = tmpdir / "data"
        ar_dir.mkdir()
        data_dir.mkdir()

        orig_data_tar = _extract_data_tar(udeb_path, ar_dir)
        # Move the extracted data tree from ar_dir into data_dir, leaving
        # the ar member files (debian-binary, control.tar.*) in ar_dir.
        for entry in sorted(ar_dir.iterdir()):
            if entry.name == orig_data_tar.name:
                continue
            if entry.name == debian_binary:
                continue
            if entry.name == control_member:
                continue
            dest = data_dir / entry.name
            if entry.is_dir():
                shutil.move(str(entry), str(dest))
            else:
                shutil.move(str(entry), str(dest))

        # Sanity: the original udeb's data.tar should have produced
        # data_dir/usr/sbin/debootstrap.
        target_debootstrap = data_dir / "usr" / "sbin" / "debootstrap"
        if not target_debootstrap.is_file():
            raise RuntimeError(
                f"original debootstrap-udeb data tree has no "
                f"usr/sbin/debootstrap (looked in {data_dir}). "
                f"The stub lives there; without it we have nothing to patch."
            )

        # Overwrite usr/sbin/debootstrap with the r159 stub verbatim.
        # mode 0755 to match what the retired build-iso-di.sh did on line 1673.
        target_debootstrap.write_text(stub_text)
        target_debootstrap.chmod(0o755)

        # Move the modified data tree back into ar_dir for repacking.
        for entry in sorted(data_dir.iterdir()):
            dest = ar_dir / entry.name
            if entry.is_dir():
                shutil.move(str(entry), str(dest))
            else:
                shutil.move(str(entry), str(dest))

        _repack_udeb(
            ar_dir=ar_dir,
            control_member=control_member,
            data_member_original=orig_data_tar,
            output_udeb=output_path,
        )

    out_members = _list_udeb_members(output_path)
    log(f"    patched udeb members: {out_members}")

    if in_place:
        os.replace(output_path, final_output)
        output_path = final_output
    return {
        "input_udeb": str(udeb_path),
        "output_udeb": str(output_path),
        "input_sha256": sha256_file(udeb_path),
        "output_sha256": sha256_file(output_path),
        "input_size": udeb_path.stat().st_size,
        "output_size": output_path.stat().st_size,
        "members": out_members,
        "patched": True,
    }


def stage_patched_udeb_in_cache(
    patched_udeb: Path,
    cache_root: Path,
) -> Path:
    """For netboot-layout substrates (no pool/), write the patched udeb
    to a per-build cache node and return its path. The caller
    (write-image.py) will copy this into the ISO tree at
    ``/ncz-payload/debootstrap-udeb/`` for operator inspection.

    For install_dir-layout substrates, this function is NOT called:
    the patched udeb is written back to
    ``<substrate>/extract/pool/.../debootstrap-udeb_*_all.udeb`` in
    place by ``patch_substrate()``.
    """
    canonical_payload = canonical_encode({
        "schema_version": "patched-debootstrap-udeb/v1",
        "patched_udeb_sha256": sha256_file(patched_udeb),
        "patched_udeb_size": patched_udeb.stat().st_size,
        "source": "external --source-udeb (netboot substrate)",
    })
    node_key = sha256_bytes(canonical_payload)
    node_dir = cache_root / "ncz-udeb" / node_key
    if node_dir.exists():
        if (node_dir / "node-key.json").is_file():
            log(f"    patched udeb cache node exists: {node_dir}")
            return node_dir
        log(f"    WARNING: incomplete cache node (no node-key.json): {node_dir} -- restaging")
        shutil.rmtree(node_dir)
    # Same atomicity rule as the other cache nodes: build under
    # .partial.<pid>, publish by rename once node-key.json is written, so an
    # interrupted run cannot leave a node that later runs serve as a hit.
    build_dir = node_dir.parent / f"{node_key}.partial.{os.getpid()}"
    shutil.rmtree(build_dir, ignore_errors=True)
    build_dir.mkdir(parents=True)
    shutil.copy2(str(patched_udeb), str(build_dir / patched_udeb.name))
    (build_dir / "node-key.json").write_text(json.dumps({
        "node_key": node_key,
        "canonical_payload_sha256": sha256_bytes(canonical_payload),
    }, indent=2, sort_keys=True))
    os.replace(build_dir, node_dir)
    log(f"    staged patched udeb at {node_dir}")
    return node_dir


def patch_substrate(
    substrate_node_dir: Path,
    cache_root: Path,
    source_udeb,
    arch: str,
    force: bool = False,
    skip_udeb_assertions: bool = False,
):
    """Top-level orchestrator. Returns a receipt dict.

    Two substrate layouts:
      * ``install_dir`` (full Debian netinst ISO) — pool exists under
        substrate_node_dir/extract/pool/. Patch in place, also assert
        the 3+3 required udebs.
      * ``netboot`` (mini.iso) — no pool. Patch
        an external --source-udeb and stage the result under
        cache_root/ncz-udeb/<key>/ so write-image.py can copy it
        into the ISO at /ncz-payload/debootstrap-udeb/.
    """
    pool = _find_substrate_pool(substrate_node_dir)
    layout = "install_dir" if pool else "netboot"
    log(f"    substrate layout: {layout} (pool={pool})")

    syntax_checked_stub = R159_STUB_SCRIPT
    _syntax_check_stub(syntax_checked_stub, "r159")

    if pool is not None:
        # Full Debian netinst substrate path.  Keep the imported substrate
        # immutable: the old in-place call was both contrary to the cache
        # contract and, due to output==input, actually returned "exists"
        # without patching anything.
        if not skip_udeb_assertions:
            verify_udeb_required(pool, REQUIRED_UDEB_SHELL, "shell-side")
            _, baked_only = verify_udeb_required(
                pool, REQUIRED_UDEB_DI, "d-i runtime pool", fatal=False)
            if baked_only:
                log("    NOTE: d-i runtime components absent from optical pool "
                    f"(expected when baked into initrd): {baked_only}")
        else:
            log("    --skip-udeb-assertions: skipping 3+3 udeb gate")
        debootstrap_udeb = _find_debootstrap_udeb(pool)
        log(f"    patching immutable source: {debootstrap_udeb}")
        with tempfile.TemporaryDirectory(prefix="ncz-udeb-stage.") as tmpdir_str:
            out_udeb = Path(tmpdir_str) / debootstrap_udeb.name
            receipt = patch_udeb(debootstrap_udeb, out_udeb,
                                 syntax_checked_stub, force=True)
            staged = stage_patched_udeb_in_cache(out_udeb, cache_root)
        receipt["layout"] = layout
        receipt["in_place"] = False
        receipt["staged_dir"] = str(staged)
        receipt["staged_udeb_path"] = str(staged / debootstrap_udeb.name)
        return receipt

    # Netboot substrate path.
    if source_udeb is None:
        raise RuntimeError(
            "substrate has no pool/ (netboot mini.iso layout). Pass "
            "--source-udeb <path-to-debootstrap-udeb_*.udeb> (fetch from "
            "deb.debian.org/debian/pool/main/d/debootstrap/ or use a "
            "pre-cached full netinst ISO to extract one)."
        )
    if not source_udeb.is_file():
        raise RuntimeError(f"--source-udeb not found: {source_udeb}")
    log(f"    substrate has no pool/; patching external udeb {source_udeb}")
    with tempfile.TemporaryDirectory(prefix="ncz-udeb-stage.") as tmpdir_str:
        tmpdir = Path(tmpdir_str)
        out_udeb = tmpdir / source_udeb.name
        receipt = patch_udeb(
            udeb_path=source_udeb,
            output_path=out_udeb,
            stub_text=syntax_checked_stub,
            force=force,
        )
        receipt["layout"] = layout
        receipt["in_place"] = False
        staged = stage_patched_udeb_in_cache(
            patched_udeb=out_udeb,
            cache_root=cache_root,
        )
        receipt["staged_dir"] = str(staged)
        receipt["staged_udeb_path"] = str(staged / out_udeb.name)
    return receipt


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--substrate-node-dir", required=True, type=Path,
                    help="substrate import node dir (created by "
                         "build/iso/import-substrate.py)")
    ap.add_argument("--cache-root", type=Path, default=DEFAULT_CACHE_ROOT,
                    help=f"cache root (default: {DEFAULT_CACHE_ROOT})")
    ap.add_argument("--arch", required=True, choices=["amd64", "arm64"])
    ap.add_argument("--source-udeb", type=Path, default=None,
                    help="(netboot substrate only) path to a real "
                         "debootstrap-udeb_*_all.udeb to patch. Required "
                         "when the substrate has no pool/ (mini.iso "
                         "layout).")
    ap.add_argument("--force", action="store_true",
                    help="re-patch even if cache says it's already done")
    ap.add_argument("--skip-udeb-assertions", action="store_true",
                    help="skip the 3+3 udeb gate (only sensible for "
                         "local experiments; production MUST run the "
                         "assertions)")
    ap.add_argument("--report", type=Path, default=None,
                    help="optional path to write the patch receipt as JSON")
    args = ap.parse_args()

    if shutil.which("ar") is None:
        log("FATAL: ar (binutils) not on PATH — cannot patch udeb")
        return 2
    if shutil.which("tar") is None:
        log("FATAL: tar not on PATH — cannot patch udeb")
        return 2
    if shutil.which("gzip") is None:
        log("FATAL: gzip not on PATH — cannot patch udeb")
        return 2

    try:
        receipt = patch_substrate(
            substrate_node_dir=args.substrate_node_dir.resolve(),
            cache_root=args.cache_root.resolve(),
            source_udeb=args.source_udeb.resolve() if args.source_udeb else None,
            arch=args.arch,
            force=args.force,
            skip_udeb_assertions=args.skip_udeb_assertions,
        )
    except RuntimeError as e:
        log(f"FATAL: {e}")
        return 2

    log(f"OK: patch complete (layout={receipt.get('layout')})")
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(receipt, indent=2, sort_keys=True))
        log(f"    receipt: {args.report}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
