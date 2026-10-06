#!/usr/bin/env python3
"""Tests for aspect-ratio wallpaper variants (docs/WALLPAPER-SAFE-AREA.md).

Run:  python3 build/test_wallpaper_fit.py
  or: python3 -m pytest build/test_wallpaper_fit.py

Covers:
  * assets/wallpaper/ncz-wallpaper-fit: variant selection by aspect ratio with
    stubbed outputs (wlr-randr, Singularity displays.json, DRM sysfs), rotation,
    unknown output, variant -> original mapping, file:// URIs;
  * the REAL ncz-wallpaper-rotate heredoc from post-install/45-wallpaper-rotator.sh
    against a stub gsettings: --refit swaps to the fitting variant and back,
    a normal rotation applies the variant, the daemon re-fits every tick;
  * build/build-wallpaper-contrib-deb.sh packages the variants outside the
    collection Dir and declares them under [Variants];
  * the committed Cygnus assets: every image has a 16:10 variant, every
    variant is 16:10 within 0.5%, the originals are still 3840x2160, and a
    pixel test that the variant's baked-in mark lies inside the safe area of
    both a 16:10 and a 16:9 cover/zoom view (needs Pillow; skipped loudly
    without it).

CHIMERA (MacBookPro16,1, 3072x1920 eDP-1, scale 2) is the panel that showed
the 16:9 originals cropping "NCZ-OS 26.10" to "NCZ-OS 26" on 2026-10-06.
"""

import hashlib
import importlib.machinery
import importlib.util
import json
import os
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
HELPER = REPO / "assets" / "wallpaper" / "ncz-wallpaper-fit"
HOOK = REPO / "post-install" / "45-wallpaper-rotator.sh"
DEB = REPO / "build" / "build-wallpaper-contrib-deb.sh"
PACK = REPO / "assets" / "branding" / "wallpaper" / "contrib" / "cygnus-2610"
VARIANTS = PACK / "16x10"

sys.dont_write_bytecode = True  # no __pycache__ next to the shipped helper
_loader = importlib.machinery.SourceFileLoader("ncz_wallpaper_fit", str(HELPER))
_spec = importlib.util.spec_from_loader("ncz_wallpaper_fit", _loader)
fit = importlib.util.module_from_spec(_spec)
_loader.exec_module(fit)


def jpeg_header(w, h):
    """Smallest byte string ncz-wallpaper-fit's header reader accepts: SOI,
    an APP0 segment to skip, then SOF0 with the dimensions."""
    app0 = (
        b"\xff\xe0"
        + struct.pack(">H", 16)
        + b"JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
    )
    sof = (
        b"\xff\xc0"
        + struct.pack(">HBHHB", 17, 8, h, w, 3)
        + b"\x01\x22\x00\x02\x11\x01\x03\x11\x01"
    )
    return b"\xff\xd8" + app0 + sof + b"\xff\xd9"


def write_exe(path, text):
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def wlr_json(*outputs):
    """outputs: (name, w, h, transform, enabled)"""
    return json.dumps(
        [
            {
                "name": n,
                "enabled": en,
                "transform": tr,
                "scale": 2.0,
                "modes": [
                    {
                        "width": w,
                        "height": h,
                        "refresh": 60.0,
                        "preferred": True,
                        "current": True,
                    },
                    {
                        "width": 1280,
                        "height": 720,
                        "refresh": 60.0,
                        "preferred": False,
                        "current": False,
                    },
                ],
            }
            for n, w, h, tr, en in outputs
        ]
    )


def cover_rect(W, H, tw, th):
    s = max(tw / W, th / H)
    vw, vh = tw / s, th / s
    x0, y0 = (W - vw) / 2, (H - vh) / 2
    return x0, y0, x0 + vw, y0 + vh


class Sandbox:
    """A fake system: one collection with a 16:9 original and a 16:10 variant,
    a PATH holding only stubs, and an empty XDG config home."""

    def __init__(self):
        self.tmp = Path(
            tempfile.mkdtemp(prefix="wallfit-", dir=os.environ.get("TMPDIR"))
        )
        t = self.tmp
        self.orig_dir = t / "backgrounds" / "pack"
        self.var_dir = t / "aspect" / "16x10" / "pack"
        self.plain_dir = t / "backgrounds" / "plain"
        self.coll = t / "collections"
        for d in (
            self.orig_dir,
            self.var_dir,
            self.plain_dir,
            self.coll,
            t / "bin",
            t / "config",
            t / "drm",
        ):
            d.mkdir(parents=True)
        for name in ("a.jpg", "b.jpg"):
            (self.orig_dir / name).write_bytes(jpeg_header(3840, 2160))
        (self.var_dir / "a.jpg").write_bytes(
            jpeg_header(3456, 2160)
        )  # b.jpg has no variant
        (self.plain_dir / "p.jpg").write_bytes(jpeg_header(3840, 2160))
        (self.coll / "pack.collection").write_text(
            f"[Collection]\nId=pack\nName=Pack\nType=static\nDir={self.orig_dir}\n\n"
            f"[Variants]\n16x10={self.var_dir}\n"
        )
        (self.coll / "plain.collection").write_text(
            f"[Collection]\nId=plain\nName=Plain\nType=static\nDir={self.plain_dir}\n"
        )
        self.env = {
            "PATH": f"{t / 'bin'}:/usr/bin:/bin",
            "HOME": str(t),
            "XDG_CONFIG_HOME": str(t / "config"),
            "XDG_RUNTIME_DIR": str(t),
            "NCZ_WALLPAPER_COLLECTION_DIRS": str(self.coll),
            "NCZ_WALLPAPER_DRM_ROOT": str(t / "drm"),
            "USER": os.environ.get("USER", "test"),
        }
        self.saved = {k: os.environ.get(k) for k in self.env}

    def wlr(self, payload):
        write_exe(
            self.tmp / "bin" / "wlr-randr",
            "#!/bin/sh\n[ \"$1\" = --json ] || exit 2\ncat <<'EOF'\n"
            + payload
            + "\nEOF\n",
        )

    def no_wlr(self):
        write_exe(self.tmp / "bin" / "wlr-randr", "#!/bin/sh\nexit 1\n")

    def displays(self, data):
        d = self.tmp / "config" / "singularity"
        d.mkdir(parents=True, exist_ok=True)
        (d / "displays.json").write_text(json.dumps(data))

    def drm(self, name, status, modes):
        d = self.tmp / "drm" / name
        d.mkdir(parents=True)
        (d / "status").write_text(status + "\n")
        (d / "modes").write_text("".join(m + "\n" for m in modes))

    def __enter__(self):
        os.environ.update(self.env)
        return self

    def __exit__(self, *exc):
        for k, v in self.saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(self.tmp, ignore_errors=True)


class OutputSize(unittest.TestCase):
    def test_wlr_randr_current_mode(self):
        with Sandbox() as sb:
            sb.wlr(wlr_json(("eDP-1", 3072, 1920, "normal", True)))
            self.assertEqual(fit.output_size(), (3072, 1920))

    def test_wlr_randr_rotation_swaps(self):
        with Sandbox() as sb:
            sb.wlr(wlr_json(("eDP-1", 3072, 1920, "90", True)))
            self.assertEqual(fit.output_size(), (1920, 3072))

    def test_shell_monitor_is_primary(self):
        with Sandbox() as sb:
            sb.wlr(
                wlr_json(
                    ("HDMI-A-1", 1920, 1080, "normal", True),
                    ("eDP-1", 3072, 1920, "normal", True),
                )
            )
            self.assertEqual(fit.output_size(), (1920, 1080))
            sb.displays({"shell_monitor": "eDP-1", "monitors": []})
            self.assertEqual(fit.output_size(), (3072, 1920))

    def test_disabled_output_ignored(self):
        with Sandbox() as sb:
            sb.wlr(
                wlr_json(
                    ("HDMI-A-1", 1920, 1080, "normal", False),
                    ("eDP-1", 2560, 1600, "normal", True),
                )
            )
            self.assertEqual(fit.output_size(), (2560, 1600))

    def test_displays_json_fallback(self):
        with Sandbox() as sb:
            sb.no_wlr()
            # CHIMERA's real displays.json shape
            sb.displays(
                {
                    "shell_monitor": "eDP-1",
                    "monitors": [
                        {
                            "name": "DP-2",
                            "enabled": True,
                            "mode_w": 1920,
                            "mode_h": 1080,
                            "transform": 0,
                        },
                        {
                            "name": "eDP-1",
                            "x": 0,
                            "y": 0,
                            "scale": 2.0,
                            "transform": 0,
                            "enabled": True,
                            "vrr_enabled": False,
                            "mode_w": 3072,
                            "mode_h": 1920,
                            "mode_r": 60000,
                        },
                    ],
                }
            )
            self.assertEqual(fit.output_size(), (3072, 1920))

    def test_sysfs_fallback_prefers_internal_panel(self):
        with Sandbox() as sb:
            sb.no_wlr()
            sb.drm("card0-DP-1", "connected", ["1920x1080"])
            sb.drm("card0-HDMI-A-1", "disconnected", [])
            sb.drm("card1-eDP-1", "connected", ["2880x1800", "1920x1200"])
            self.assertEqual(fit.output_size(), (2880, 1800))

    def test_unknown(self):
        with Sandbox() as sb:
            sb.no_wlr()
            self.assertIsNone(fit.output_size())


class Choose(unittest.TestCase):
    def test_variant_by_aspect(self):
        with Sandbox() as sb:
            a, v = str(sb.orig_dir / "a.jpg"), str(sb.var_dir / "a.jpg")
            for size, want in [
                ((3072, 1920), v),
                ((2560, 1600), v),
                ((2880, 1800), v),
                ((1920, 1200), v),
                ((1920, 1080), a),
                ((1366, 768), a),
                ((3840, 2160), a),
            ]:
                self.assertEqual(fit.choose(a, size), want, size)

    def test_unknown_output_keeps_original(self):
        with Sandbox() as sb:
            a = str(sb.orig_dir / "a.jpg")
            self.assertEqual(fit.choose(a, None), a)

    def test_variant_maps_back_to_original(self):
        with Sandbox() as sb:
            a, v = str(sb.orig_dir / "a.jpg"), str(sb.var_dir / "a.jpg")
            self.assertEqual(fit.choose(v, (1920, 1080)), a)
            self.assertEqual(fit.choose(v, (3072, 1920)), v)

    def test_no_variant_for_this_image(self):
        with Sandbox() as sb:
            b = str(sb.orig_dir / "b.jpg")
            self.assertEqual(fit.choose(b, (3072, 1920)), b)

    def test_collection_without_variants(self):
        with Sandbox() as sb:
            p = str(sb.plain_dir / "p.jpg")
            self.assertEqual(fit.choose(p, (3072, 1920)), p)

    def test_uri(self):
        with Sandbox() as sb:
            a, v = sb.orig_dir / "a.jpg", sb.var_dir / "a.jpg"
            self.assertEqual(fit.choose_uri(f"file://{a}", (3072, 1920)), f"file://{v}")
            self.assertEqual(fit.choose_uri(f"file://{a}", (1920, 1080)), f"file://{a}")
            self.assertEqual(
                fit.choose_uri("https://example.org/x.jpg", (3072, 1920)),
                "https://example.org/x.jpg",
            )

    def test_cli_uses_stubbed_output(self):
        with Sandbox() as sb:
            sb.wlr(wlr_json(("eDP-1", 3072, 1920, "normal", True)))
            a, v = sb.orig_dir / "a.jpg", sb.var_dir / "a.jpg"
            out = subprocess.run(
                [sys.executable, str(HELPER), "choose", str(a)],
                env=sb.env,
                capture_output=True,
                text=True,
                check=True,
            ).stdout.strip()
            self.assertEqual(out, str(v))
            out = subprocess.run(
                [sys.executable, str(HELPER), "output-size"],
                env=sb.env,
                capture_output=True,
                text=True,
                check=True,
            ).stdout.strip()
            self.assertEqual(out, "3072x1920")

    def test_corrupt_jpeg_length_terminates(self):
        with Sandbox() as sb:
            bad = sb.tmp / "bad.jpg"
            # SOI, then an APP0 whose length (0) is shorter than its own field
            bad.write_bytes(b"\xff\xd8\xff\xe0\x00\x00" + b"\x00" * 64)
            self.assertIsNone(fit.image_size(str(bad)))
            sos = sb.tmp / "sos.jpg"
            sos.write_bytes(b"\xff\xd8\xff\xda\x00\x08" + b"\x00" * 64)
            self.assertIsNone(fit.image_size(str(sos)))

    def test_zero_sizes_rejected(self):
        with Sandbox() as sb:
            a = str(sb.orig_dir / "a.jpg")
            self.assertEqual(fit.choose(a, (3072, 0)), a)
            sb.no_wlr()
            sb.drm("card0-eDP-1", "connected", ["0x0"])
            self.assertIsNone(fit.output_size())

    def test_cli_never_fails(self):
        with Sandbox() as sb:
            sb.no_wlr()
            r = subprocess.run(
                [sys.executable, str(HELPER), "choose", "/nonexistent/x.jpg"],
                env=sb.env,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(
                (r.returncode, r.stdout.strip()), (0, "/nonexistent/x.jpg")
            )


def extract_heredoc(marker):
    lines, on = [], False
    for line in HOOK.read_text().splitlines():
        if not on and f"<<'{marker}'" in line:
            on = True
            continue
        if on and line == marker:
            break
        if on:
            lines.append(line)
    return "\n".join(lines) + "\n"


class Rotator(unittest.TestCase):
    """The real ncz-wallpaper-rotate against stub gsettings/systemctl."""

    def setUp(self):
        self.sb = Sandbox()
        t = self.sb.tmp
        self.rot = t / "ncz-wallpaper-rotate"
        write_exe(self.rot, extract_heredoc("ROT"))
        (t / "schemas").mkdir()
        self.log = t / "gsettings.log"
        self.cur = t / "current"
        write_exe(
            t / "bin" / "gsettings",
            "#!/bin/sh\n"
            f'if [ "$1" = get ]; then printf "\'%s\'\\n" "$(cat {self.cur})"; exit 0; fi\n'
            f'if [ "$1" = set ]; then echo "$3 $4" >> {self.log}; printf %s "$4" > {self.cur}; fi\n',
        )
        write_exe(t / "bin" / "systemctl", "#!/bin/sh\nexit 0\n")
        write_exe(
            t / "bin" / "collections",
            f'#!/bin/sh\n[ "$1" = pick ] && echo {self.sb.orig_dir / "a.jpg"}\n[ "$1" = path ] && exit 0\nexit 0\n',
        )
        self.env = dict(
            self.sb.env,
            XDG_CURRENT_DESKTOP="Singularity",
            NCZ_SINGULARITY_SCHEMA_DIR=str(t / "schemas"),
            NCZ_WALLPAPER_FIT=str(HELPER),
            NCZ_WALLPAPER_COLLECTIONS=str(t / "bin" / "collections"),
        )

    def tearDown(self):
        shutil.rmtree(self.sb.tmp, ignore_errors=True)

    def run_rot(self, *args):
        return subprocess.run(
            [str(self.rot), *args],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )

    def sets(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def test_refit_swaps_to_variant_on_16x10(self):
        self.sb.wlr(wlr_json(("eDP-1", 3072, 1920, "normal", True)))
        self.cur.write_text(f"file://{self.sb.orig_dir / 'a.jpg'}")
        self.run_rot("--refit")
        self.assertEqual(
            self.sets(), [f"background-picture-uri file://{self.sb.var_dir / 'a.jpg'}"]
        )
        self.run_rot("--refit")  # idempotent: nothing more to write
        self.assertEqual(len(self.sets()), 1)

    def test_refit_back_to_original_on_16x9(self):
        self.sb.wlr(wlr_json(("HDMI-A-1", 1920, 1080, "normal", True)))
        self.cur.write_text(f"file://{self.sb.var_dir / 'a.jpg'}")
        self.run_rot("--refit")
        self.assertEqual(
            self.sets(), [f"background-picture-uri file://{self.sb.orig_dir / 'a.jpg'}"]
        )

    def test_refit_noop_when_fitting(self):
        self.sb.wlr(wlr_json(("HDMI-A-1", 1920, 1080, "normal", True)))
        self.cur.write_text(f"file://{self.sb.orig_dir / 'a.jpg'}")
        self.run_rot("--refit")
        self.assertEqual(self.sets(), [])
        # and --refit never advances the rotation state
        self.assertFalse((self.sb.tmp / "ncz-wallpaper-state").exists())

    def test_rotation_applies_variant(self):
        self.sb.wlr(wlr_json(("eDP-1", 3072, 1920, "normal", True)))
        self.cur.write_text("")
        r = self.run_rot()
        self.assertEqual(
            self.sets(),
            [f"background-picture-uri file://{self.sb.var_dir / 'a.jpg'}"],
            r.stderr,
        )

    def test_rotation_without_helper_keeps_original(self):
        self.sb.wlr(wlr_json(("eDP-1", 3072, 1920, "normal", True)))
        self.cur.write_text("")
        self.env["NCZ_WALLPAPER_FIT"] = str(self.sb.tmp / "missing")
        self.run_rot()
        self.assertEqual(
            self.sets(), [f"background-picture-uri file://{self.sb.orig_dir / 'a.jpg'}"]
        )

    def test_daemon_refits_every_tick(self):
        daemon = extract_heredoc("DAEMON")
        loop = daemon[daemon.index("while true; do") :]
        self.assertIn("/usr/local/bin/ncz-wallpaper-rotate --refit", loop)
        self.assertLess(
            loop.index("--refit"),
            loop.index('[ $((now - last_rotate)) -lt "$interval" ]'),
        )
        self.assertRegex(daemon, r"\nTICK=\d+\n")
        self.assertIn('sleep "$TICK"', loop)

    def test_hook_installs_helper(self):
        text = HOOK.read_text()
        self.assertIn(
            'install -m 0755 "$OCS_ASSETS/ncz-wallpaper-fit" /usr/local/bin/ncz-wallpaper-fit',
            text,
        )


class DebPackaging(unittest.TestCase):
    """Run the real deb builder with a stub dpkg-deb that keeps the tree."""

    def test_variants_packaged_outside_collection_dir(self):
        if not shutil.which("bash"):
            self.skipTest("bash missing")
        with tempfile.TemporaryDirectory(
            prefix="wallfit-deb-", dir=os.environ.get("TMPDIR")
        ) as td:
            t = Path(td)
            ap = t / "artistpack" / "cygnus-2610"
            ap.mkdir(parents=True)
            (ap / "artist.json").write_text("{}\n")
            (ap / "pack.json").write_text("{}\n")
            (t / "bin").mkdir()
            write_exe(
                t / "bin" / "dpkg-deb",
                '#!/bin/sh\n[ "$1" = --info ] && exit 0\n'
                f'cp -a "$3" {t / "tree"}\n: > "$4"\n',
            )
            env = dict(
                os.environ,
                PATH=f"{t / 'bin'}:{os.environ.get('PATH', '/usr/bin:/bin')}",
                ARTISTPACK_SOURCE_ROOT=str(t / "artistpack"),
                WALLPAPER_DEB_OUT=str(t / "out"),
                TMPDIR=str(t),
            )
            r = subprocess.run(
                ["bash", str(DEB), "cygnus-2610"],
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            tree = t / "tree"
            originals = sorted(
                p.name
                for p in (tree / "usr/share/backgrounds/ncz/cygnus-2610").iterdir()
            )
            variants = sorted(
                p.name
                for p in (
                    tree / "usr/share/ncz-wallpapers/aspect/16x10/cygnus-2610"
                ).iterdir()
            )
            self.assertEqual(len(originals), 12)
            self.assertEqual(originals, variants)
            self.assertFalse(
                (tree / "usr/share/backgrounds/ncz/cygnus-2610/16x10").exists(),
                "variants inside the collection Dir would be listed twice by the shell",
            )
            coll = (
                tree
                / "opt/singularity/share/singularity/wallpaper-collections/cygnus-2610.collection"
            ).read_text()
            self.assertIn(
                "[Variants]\n16x10=/usr/share/ncz-wallpapers/aspect/16x10/cygnus-2610\n",
                coll,
            )
            self.assertIn("Dir=/usr/share/backgrounds/ncz/cygnus-2610\n", coll)


class CygnusAssets(unittest.TestCase):
    def originals(self):
        return sorted(p for p in PACK.glob("*.jpg"))

    def test_every_image_has_a_variant(self):
        names = [p.name for p in self.originals()]
        self.assertEqual(len(names), 12)
        self.assertEqual(names, sorted(p.name for p in VARIANTS.glob("*.jpg")))

    def test_variant_ratio_16x10(self):
        for p in VARIANTS.glob("*.jpg"):
            w, h = fit.image_size(str(p))
            self.assertLess(abs((w / h) / 1.6 - 1), 0.005, (p.name, w, h))

    def test_originals_untouched_16x9(self):
        for p in self.originals():
            self.assertEqual(fit.image_size(str(p)), (3840, 2160), p.name)

    def test_manifest_matches_files(self):
        meta = json.loads((VARIANTS / "VARIANTS.json").read_text())
        self.assertEqual(meta["aspect"], "16x10")
        self.assertEqual(
            sorted(meta["files"]), sorted(p.name for p in VARIANTS.glob("*.jpg"))
        )
        for name, m in meta["files"].items():
            self.assertEqual(
                hashlib.sha256((VARIANTS / name).read_bytes()).hexdigest(),
                m["sha256"],
                name,
            )
            x0, y0, x1, y1 = m["crop"]
            self.assertEqual((x1 - x0, y1 - y0), tuple(meta["size"]), name)
            self.assertTrue(0 <= x0 and x1 <= 3840 and y0 == 0 and y1 == 2160, name)

    def test_mark_inside_safe_area(self):
        """Locate the variant's baked-in mark by pixels -- where it is brighter
        than the same window of the 16:9 original, away from the original's
        own mark -- and require the whole mark inside the 16:10 view and the
        16:9 cover/zoom view of the variant, 64 px clear of every edge."""
        try:
            from PIL import Image, ImageChops, ImageFilter
        except ImportError:
            print(
                "\n*** SKIP test_mark_inside_safe_area: Pillow (python3-pil) is not installed ***",
                file=sys.stderr,
            )
            self.skipTest("Pillow not installed")
        meta = json.loads((VARIANTS / "VARIANTS.json").read_text())["files"]
        inset = 64
        for name, m in sorted(meta.items()):
            var = Image.open(VARIANTS / name).convert("L")
            orig = Image.open(PACK / name).convert("L").crop(tuple(m["crop"]))
            W, H = var.size
            # Search the lower-right quarter (both marks live there; the full
            # frame only makes the max filter slow). Coordinates are mapped
            # back to the full variant afterwards.
            bx, by = W // 2, H // 2
            var_q, orig_q = var.crop((bx, by, W, H)), orig.crop((bx, by, W, H))
            glyphs = ImageChops.subtract(var_q, orig_q).point(
                lambda v: 255 if v > 40 else 0
            )
            orig_mark = ImageChops.subtract(orig_q, var_q).point(
                lambda v: 255 if v > 40 else 0
            )
            # The original's glyphs plus their shadow: dilate by ~60 px (a 15 px
            # max filter at quarter scale -- the same reach, a fraction of the time).
            q = orig_mark.size
            orig_zone = (
                orig_mark.resize((q[0] // 4, q[1] // 4), Image.BOX)
                .point(lambda v: 255 if v else 0)
                .filter(ImageFilter.MaxFilter(15))
                .resize(q, Image.NEAREST)
            )
            qbox = ImageChops.subtract(glyphs, orig_zone).getbbox()
            self.assertIsNotNone(qbox, f"{name}: no mark found")
            box = (qbox[0] + bx, qbox[1] + by, qbox[2] + bx, qbox[3] + by)
            # the whole "CYGNUS . NCZ-OS 26.10" line is present (the 4K mark is ~690 px wide)
            self.assertGreater(
                box[2] - box[0], 600, f"{name}: mark {box} looks truncated"
            )
            self.assertLess(box[3] - box[1], 60, f"{name}: mark {box} is not one line")
            for tw, th in ((3072, 1920), (1920, 1080), (2560, 1600), (1366, 768)):
                x0, y0, x1, y1 = cover_rect(W, H, tw, th)
                inside = (
                    box[0] >= x0 + inset
                    and box[1] >= y0 + inset
                    and box[2] <= x1 - inset
                    and box[3] <= y1 - inset
                )
                self.assertTrue(
                    inside,
                    f"{name}: mark {box} outside the safe area of a {tw}x{th} view "
                    f"({x0:.0f},{y0:.0f})-({x1:.0f},{y1:.0f}) inset {inset}",
                )

    def test_original_mark_is_cropped_on_16x10(self):
        """Documents the defect the variants fix: under cover/zoom on a 16:10
        panel the original's mark runs past the visible right edge."""
        try:
            from PIL import Image
        except ImportError:
            self.skipTest("Pillow not installed")
        meta = json.loads((VARIANTS / "VARIANTS.json").read_text())["files"]
        name = "cygnus-single-kipthorne.jpg"
        orig = Image.open(PACK / name).convert("L")
        x0 = meta[name]["crop"][0]
        var_window = Image.open(VARIANTS / name).convert("L")
        # bright glyph columns in the original's bottom band
        band = orig.crop((2800, 2010, 3840, 2070))
        cols = [
            x
            for x in range(band.width)
            if max(band.crop((x, 0, x + 1, band.height)).getdata()) > 200
        ]
        right = 2800 + max(cols)
        _, _, vis_right, _ = cover_rect(3840, 2160, 3072, 1920)
        self.assertGreater(
            right,
            vis_right,
            "the 16:9 original is no longer cropped; re-check the premise",
        )
        self.assertEqual(var_window.size, (3456, 2160))
        self.assertEqual(x0, 192)


if __name__ == "__main__":
    unittest.main(verbosity=1)
