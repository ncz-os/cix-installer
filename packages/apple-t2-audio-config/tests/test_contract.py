#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jason Perlow
"""Contract tests for the apple-t2-audio-config generator and build script.

Run them from anywhere:

    python3 -m unittest discover -s packages/apple-t2-audio-config/tests -v
    python3 packages/apple-t2-audio-config/tests/test_contract.py

Standard library only, no network, no root, nothing written outside a
per-test temporary directory. The tests never install the package and never
parse UCM: they assert the emitted key, channel, path and API contract with
plain text and regular-expression checks. Accepting the files with the
installed ALSA libraries is a separate supervisor runtime gate - see
``../README.md``.

Covered:

* the six-path contract for x2/x4/x6 (card file + use case file per layout);
* the real UCM Syntax 6 shape of both file kinds, and the absence of the
  invented DSL the previous candidate emitted;
* the card file binding - its ``File`` value is exactly the use case file this
  run generated;
* every route's real ``SectionDevice``/``Value`` keys (PCM, channels, rate,
  priority, jack control, conflicting device);
* the speaker contract: all physical channels of a layout are preserved, the
  channel map is the identity map, and no application-channel projection
  appears;
* package metadata, payload modes, reproducibility, refusals that must happen
  before anything is written, and the build script's scratch-ownership rules.
"""

from __future__ import annotations

import contextlib
import gzip
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

PKG_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DIR = os.path.join(PKG_DIR, "src")
if SRC_DIR not in sys.path:
    sys.path.insert(0, SRC_DIR)

import applet2_ucm as gen  # noqa: E402

FACTS_PATH = os.path.join(SRC_DIR, "facts.json")
LICENSE_PATH = os.path.join(PKG_DIR, "LICENSE")
README_PATH = os.path.join(PKG_DIR, "README.md")
BUILD_SCRIPT = os.path.join(PKG_DIR, "build-deb.sh")
RETIRED_PARSER = os.path.join(SRC_DIR, "ucm_parse.py")

UCM_ROOT = "/usr/share/alsa/ucm2"
LAYOUTS = (2, 4, 6)
POSITIONS = {
    2: ["FL", "FR"],
    4: ["FL", "FR", "RL", "RR"],
    6: ["FL", "SL", "RL", "FR", "SR", "RR"],
}
SPEAKER_COUNT_KEYS = ("Channels", "HWChannels")
SPEAKER_POSITION_KEYS = ("HWChannelPos", "ChannelPos")
ROUTES = (
    # name, direction, pcm device, channels, rate, priority, jack, conflict
    ("Headphones", "Playback", 2, 2, None, 300, "Codec Output Jack", "Speaker"),
    ("Mic", "Capture", 1, 3, 48000, 300, None, "Headset"),
    ("Headset", "Capture", 3, 1, None, 200, "Codec Output Jack", "Mic"),
)


# --------------------------------------------------------------------------
# text helpers - deliberately dumb. They locate a block and hand back its
# lines; they assign no meaning to the content beyond indentation.
# --------------------------------------------------------------------------


def code_lines(text):
    """Non-blank lines with comments and surrounding space removed."""
    lines = []
    for raw in text.splitlines():
        stripped = raw.split("#", 1)[0].rstrip()
        if stripped.strip():
            lines.append(stripped)
    return lines


def block(text, header):
    """Return the lines inside the block whose first line is exactly ``header``.

    Accepts the whole file as text or a list of lines from an enclosing
    ``block``. Brace counting only; no key/value interpretation.
    """
    lines = text.splitlines() if isinstance(text, str) else list(text)
    for index, line in enumerate(lines):
        if line.rstrip() == header:
            depth = line.count("{") - line.count("}")
            body = []
            for candidate in lines[index + 1 :]:
                depth += candidate.count("{") - candidate.count("}")
                if depth <= 0:
                    return body
                body.append(candidate)
            return body
    raise AssertionError("block %r not found" % header)


def block_map(lines):
    """Return only direct scalar lines, excluding nested compound bodies."""
    found = {}
    depth = 0
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        change = line.count("{") - line.count("}")
        if depth == 0 and change == 0 and stripped != "}":
            found[stripped] = True
        depth += change
    return found


def load_facts():
    with open(FACTS_PATH, "r", encoding="utf-8") as handle:
        return json.load(handle)


def control_fields(text):
    fields = {}
    for line in text.splitlines():
        if not line or line[0] in " \t":
            continue
        key, sep, value = line.partition(":")
        if sep:
            fields[key.strip()] = value.strip()
    return fields


class GeneratorTestCase(unittest.TestCase):
    """Common helpers: render into a temporary directory and read it back."""

    def setUp(self):
        self._tmp = tempfile.mkdtemp(prefix="apple-t2-audio-config-test.")
        self.addCleanup(shutil.rmtree, self._tmp, ignore_errors=True)
        self.facts = load_facts()

    def run_generator(
        self,
        out_dir=None,
        layout="all",
        facts_path=FACTS_PATH,
        source_dir=PKG_DIR,
        epoch=gen.DEFAULT_SOURCE_DATE_EPOCH,
        validate_only=False,
    ):
        """Call the CLI in-process; return (rc, stdout+stderr text)."""
        target = out_dir if out_dir is not None else os.path.join(self._tmp, "staging")
        argv = [
            "--facts",
            facts_path,
            "--source-dir",
            source_dir,
            "--out-dir",
            target,
            "--layout",
            layout,
            "--source-date-epoch",
            str(epoch),
        ]
        if validate_only:
            argv.append("--validate-only")
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            rc = gen.main(argv)
        return rc, stdout.getvalue() + stderr.getvalue()

    def render(self, layout="all", name="staging"):
        target = os.path.join(self._tmp, name)
        rc, err = self.run_generator(out_dir=target, layout=layout)
        self.assertEqual(rc, 0, err)
        self.assertTrue(os.path.isdir(target))
        return target

    @staticmethod
    def read(staging, relative):
        with open(os.path.join(staging, relative), "rb") as handle:
            return handle.read()

    @staticmethod
    def text(staging, relative):
        return GeneratorTestCase.read(staging, relative).decode("utf-8")

    @staticmethod
    def staged_files(staging):
        found = []
        for base, _dirs, files in os.walk(staging):
            for name in files:
                found.append(os.path.relpath(os.path.join(base, name), staging))
        return sorted(found)

    # path helpers, straight from the generator, so the tests cannot drift
    @staticmethod
    def card_path(layout):
        card = "AppleT2x%d" % layout
        return "%s/conf.d/%s/%s.conf" % (UCM_ROOT, card, card)

    @staticmethod
    def master_path(layout):
        return "%s/AppleT2/HiFi-x%d.conf" % (UCM_ROOT, layout)

    def card_text(self, staging, layout):
        return self.text(staging, self.card_path(layout).lstrip("/"))

    def master_text(self, staging, layout):
        return self.text(staging, self.master_path(layout).lstrip("/"))


class LayoutPathTests(GeneratorTestCase):
    def test_exactly_six_ucm_paths_for_every_layout(self):
        staging = self.render()
        paths = {
            path
            for path in self.staged_files(staging)
            if path.startswith("usr/share/alsa/")
        }
        self.assertEqual(
            paths,
            {self.master_path(n).lstrip("/") for n in LAYOUTS}
            | {self.card_path(n).lstrip("/") for n in LAYOUTS},
        )
        self.assertEqual(len(paths), 6)

    def test_no_extra_payload_beyond_docs_and_debian(self):
        staging = self.render()
        self.assertEqual(
            self.staged_files(staging),
            sorted(
                [self.master_path(n).lstrip("/") for n in LAYOUTS]
                + [self.card_path(n).lstrip("/") for n in LAYOUTS]
                + [
                    "DEBIAN/control",
                    "DEBIAN/copyright",
                    "usr/share/doc/apple-t2-audio-config/copyright",
                    "usr/share/doc/apple-t2-audio-config/changelog.Debian.gz",
                ]
            ),
        )

    def test_single_layout_render_is_exactly_two_ucm_files(self):
        staging = self.render(layout="6")
        paths = {
            path
            for path in self.staged_files(staging)
            if path.startswith("usr/share/alsa/")
        }
        self.assertEqual(
            paths,
            {self.master_path(6).lstrip("/"), self.card_path(6).lstrip("/")},
        )

    def test_generated_header_marks_the_file_as_generated(self):
        staging = self.render()
        for layout in LAYOUTS:
            for text in (
                self.card_text(staging, layout),
                self.master_text(staging, layout),
            ):
                header = [line for line in text.splitlines() if line.startswith("#")]
                self.assertTrue(header)
                self.assertIn("GENERATED, DO NOT EDIT", header[0])

    def test_card_file_declares_syntax_6_and_one_use_case(self):
        staging = self.render()
        for layout in LAYOUTS:
            text = self.card_text(staging, layout)
            code = code_lines(text)
            self.assertEqual(code[0], "Syntax 6", self.card_path(layout))
            uses = [line for line in code if line.startswith("SectionUseCase")]
            self.assertEqual(len(uses), 1, self.card_path(layout))
            self.assertEqual(uses[0], 'SectionUseCase."HiFi" {', self.card_path(layout))
            self.assertEqual(len([line for line in code if line == "}"]), 1)

    def test_card_binding_points_at_the_generated_use_case_file(self):
        staging = self.render()
        for layout in LAYOUTS:
            values = block_map(
                block(self.card_text(staging, layout), 'SectionUseCase."HiFi" {')
            )
            self.assertIn('File "/AppleT2/HiFi-x%d.conf"' % layout, values)
            # the File value is exactly the path this run generated
            self.assertEqual(
                'File "%s"' % gen.master_config_link(self.facts, layout),
                [key for key in values if key.startswith("File ")][0],
            )
            self.assertTrue(
                os.path.isfile(
                    os.path.join(
                        staging,
                        gen.master_config_payload_path(self.facts, layout),
                    )
                ),
                self.master_path(layout),
            )

    def test_card_file_carries_no_device_or_macro_grammar(self):
        staging = self.render()
        for layout in LAYOUTS:
            text = self.card_text(staging, layout)
            for marker in (
                "SectionDevice",
                "SectionVerb",
                "Macro.",
                "Include.",
                "Value {",
            ):
                self.assertNotIn(marker, text, self.card_path(layout))

    def test_card_file_no_longer_uses_the_confdir_prlude(self):
        staging = self.render()
        for layout in LAYOUTS:
            text = self.card_text(staging, layout)
            for marker in ("<confdir:cards>", "<confdir:default>", "<confdir:pcm>"):
                self.assertNotIn(marker, text, self.card_path(layout))


class UseCaseGrammarTests(GeneratorTestCase):
    """The HiFi-x<n>.conf use case file: real keys, no invented DSL."""

    def test_split_conf_is_included_by_path(self):
        staging = self.render()
        for layout in LAYOUTS:
            text = self.master_text(staging, layout)
            self.assertIn(
                'Include.pcm_split.File "/common/pcm/split.conf"',
                text,
                self.master_path(layout),
            )

    def test_section_verb_carries_the_verb_in_a_value_block(self):
        staging = self.render()
        for layout in LAYOUTS:
            body = block(self.master_text(staging, layout), "SectionVerb {")
            values = block_map(block(body, "\tValue {"))
            self.assertIn('TQ "HiFi"', values)
            self.assertNotIn("Index 0", block_map(body))

    def test_every_route_is_a_section_device_with_real_value_keys(self):
        staging = self.render()
        for layout in LAYOUTS:
            text = self.master_text(staging, layout)
            devices = [
                line.strip()
                for line in code_lines(text)
                if line.strip().startswith("SectionDevice.")
            ]
            self.assertEqual(
                sorted(devices),
                sorted(
                    'SectionDevice."%s" {' % name
                    for name in ("Speaker", "Headphones", "Mic", "Headset")
                ),
                self.master_path(layout),
            )

    def test_route_values_match_the_observed_facts(self):
        staging = self.render()
        for layout in LAYOUTS:
            text = self.master_text(staging, layout)
            for (
                name,
                direction,
                device,
                channels,
                rate,
                priority,
                jack,
                conflict,
            ) in ROUTES:
                prefix = "Playback" if direction == "Playback" else "Capture"
                body = block(text, 'SectionDevice."%s" {' % name)
                values = block_map(block(body, "\tValue {"))
                self.assertIn(
                    '%sPCM "hw:${CardId},%d"' % (prefix, device), values, name
                )
                self.assertIn("%sChannels %d" % (prefix, channels), values, name)
                self.assertIn("%sPriority %d" % (prefix, priority), values, name)
                self.assertIn('\tConflictingDevice [ "%s" ]' % conflict, body, name)
                if rate is not None:
                    self.assertIn("%sRate %d" % (prefix, rate), values, name)
                else:
                    self.assertNotIn("%sRate " % prefix, "".join(values), name)
                if jack is not None:
                    self.assertIn('JackControl "%s"' % jack, values, name)
                else:
                    self.assertNotIn("JackControl", "".join(values), name)

    def test_speaker_device_uses_the_standard_playback_priority(self):
        staging = self.render()
        for layout in LAYOUTS:
            values = block_map(
                block(
                    block(
                        self.master_text(staging, layout), 'SectionDevice."Speaker" {'
                    ),
                    "\tValue {",
                )
            )
            self.assertIn("PlaybackPriority 100", values)

    def test_no_invented_dsl_anywhere_in_the_payload(self):
        staging = self.render()
        forbidden = (
            "SectionUCM",
            "SectionDev ",
            "SectionDev{",
            "SectionPCMAuto",
            "SectionPCM {",
            "PCM.Playback",
            "PCM.Capture",
            "Devices {",
            "Macro.@",
            '"key=value"',
            "Priority ",
            "Jack ",
        )
        for layout in LAYOUTS:
            for text in (
                self.card_text(staging, layout),
                self.master_text(staging, layout),
            ):
                code = "\n".join(code_lines(text))
                for marker in forbidden:
                    if marker in ("Priority ", "Jack ", "Channels ", "Rate "):
                        # bare keyword lines only: real keys are prefixed
                        pattern = (
                            r"(?m)^\s*(?<![\w.])(?:%s)\b"
                            % marker.strip().replace(" ", r"\s")
                        )
                        self.assertNotRegex(
                            code, pattern, (self.master_path(layout), marker)
                        )
                    else:
                        self.assertNotIn(
                            marker, code, (self.master_path(layout), marker)
                        )

    def test_no_dsp_or_speaker_protection_sections(self):
        staging = self.render()
        forbidden = (
            "SectionDsp",
            "SectionDspBase",
            "SectionSpeakers",
            "SpeakerProtection",
            "SectionSwitch",
            "SectionMixer",
            "EnableDsp",
            "SectionEngine",
        )
        for layout in LAYOUTS:
            for text in (
                self.card_text(staging, layout),
                self.master_text(staging, layout),
            ):
                for marker in forbidden:
                    self.assertNotIn(marker, text, (self.master_path(layout), marker))


class SpeakerChannelContractTests(GeneratorTestCase):
    """Every physical channel of a layout survives into the application."""

    def speaker_macro(self, text, which):
        return block(text, "Macro.t2_speaker.%s {" % which)

    def test_stream_definition_keeps_every_hardware_channel(self):
        staging = self.render()
        for layout in LAYOUTS:
            values = block_map(
                self.speaker_macro(self.master_text(staging, layout), "SplitPCM")
            )
            self.assertIn('Name "t2_speaker_split"', values)
            self.assertIn("Direction Playback", values)
            self.assertIn("Format S24_LE", values)
            self.assertIn("Channels %d" % layout, values)
            self.assertIn("HWChannels %d" % layout, values)
            for index, position in enumerate(POSITIONS[layout]):
                self.assertIn(
                    "HWChannelPos%d %s" % (index, position),
                    values,
                    self.master_path(layout),
                )

    def test_device_binding_maps_every_channel_to_itself(self):
        staging = self.render()
        for layout in LAYOUTS:
            body = self.speaker_macro(
                self.master_text(staging, layout), "SplitPCMDevice"
            )
            values = block_map(body)
            self.assertIn('Name "t2_speaker_split"', values)
            self.assertIn("Direction Playback", values)
            self.assertIn("Device 0", values)
            self.assertIn("Channels %d" % layout, values)
            self.assertIn("HWChannels %d" % layout, values)
            for index, position in enumerate(POSITIONS[layout]):
                self.assertIn("Channel%d %d" % (index, index), values)
                self.assertIn("ChannelPos%d %s" % (index, position), values)

    def test_all_hw_channel_positions_are_declared_in_order(self):
        staging = self.render()
        for layout in LAYOUTS:
            text = self.master_text(staging, layout)
            for key, macro in (
                ("HWChannelPos", "SplitPCM"),
                ("ChannelPos", "SplitPCMDevice"),
            ):
                values = block_map(self.speaker_macro(text, macro))
                for index, position in enumerate(POSITIONS[layout]):
                    self.assertIn("%s%d %s" % (key, index, position), values)

    def test_no_application_channel_projection_survives(self):
        staging = self.render()
        for layout in LAYOUTS:
            text = self.master_text(staging, layout)
            self.assertNotIn("app_channels", text)
            for key in SPEAKER_COUNT_KEYS:
                for found in re.findall(r"(?m)^\s*%s (\d+)" % key, text):
                    self.assertEqual(
                        int(found),
                        layout,
                        "%s: %s is not the full layout"
                        % (self.master_path(layout), key),
                    )

    def test_only_the_speaker_channel_count_differs_between_layouts(self):
        staging = self.render()
        for layout in LAYOUTS:
            text = self.master_text(staging, layout)
            for (
                name,
                direction,
                _device,
                channels,
                _rate,
                _priority,
                _jack,
                _conflict,
            ) in ROUTES:
                prefix = "Playback" if direction == "Playback" else "Capture"
                values = block_map(
                    block(block(text, 'SectionDevice."%s" {' % name), "\tValue {")
                )
                self.assertIn("%sChannels %d" % (prefix, channels), values, name)


class PayloadContentTests(GeneratorTestCase):
    def test_payload_ships_no_pipewire_or_dsp_files(self):
        staging = self.render()
        for path in self.staged_files(staging):
            self.assertNotIn("pipewire", path.lower())
            self.assertNotIn("wireplumber", path.lower())
            self.assertNotIn("dsp", path.lower())

    def test_headroom_configuration_is_not_referenced_by_the_payload(self):
        staging = self.render()
        for layout in LAYOUTS:
            for text in (
                self.card_text(staging, layout),
                self.master_text(staging, layout),
            ):
                self.assertNotIn("99-ncz-audio-headroom", text)
        self.assertIn("99-ncz-audio-headroom", self.facts["untouched_paths"][0])

    def test_payload_contains_no_third_party_identifiers(self):
        staging = self.render()
        denied = (
            "KaiT2en",
            "lemmyg",
            "t2-ubuntu-repo",
            "AdityaGarg",
            "libmysoft",
            "speakerprotection",
            "asrc",
            "volume-curve",
        )
        for layout in LAYOUTS:
            for text in (
                self.card_text(staging, layout),
                self.master_text(staging, layout),
            ):
                for marker in denied:
                    self.assertNotIn(marker, text, (self.master_path(layout), marker))

    def test_control_metadata(self):
        staging = self.render()
        fields = control_fields(self.text(staging, "DEBIAN/control"))
        self.assertEqual(fields["Package"], "apple-t2-audio-config")
        self.assertEqual(fields["Version"], "0.5.1+ncz1")
        self.assertEqual(fields["Architecture"], "all")
        self.assertEqual(fields["Depends"], "alsa-ucm-conf (>= 1.2.16)")
        self.assertEqual(fields["Section"], "sound")
        self.assertEqual(fields["Maintainer"], "Jason Perlow <jperlow@gmail.com>")
        self.assertTrue(fields["Installed-Size"].isdigit())
        self.assertGreater(int(fields["Installed-Size"]), 0)

    def test_no_maintainer_scripts_in_the_package(self):
        staging = self.render()
        self.assertEqual(
            sorted(os.listdir(os.path.join(staging, "DEBIAN"))),
            ["control", "copyright"],
        )

    def test_copyright_carries_mit_and_the_public_alsa_notice(self):
        staging = self.render()
        for path in (
            "DEBIAN/copyright",
            "usr/share/doc/apple-t2-audio-config/copyright",
        ):
            text = self.text(staging, path)
            self.assertIn("MIT License", text, path)
            self.assertIn("Jason Perlow", text, path)
            self.assertIn("2026 Jason Perlow", text, path)
            self.assertIn("BSD 3-Clause License", text, path)
            self.assertIn("Advanced Linux Sound Architecture", text, path)

    def test_repository_license_is_mit_with_this_copyright(self):
        with open(LICENSE_PATH, "r", encoding="utf-8") as handle:
            text = handle.read()
        self.assertIn("MIT License", text)
        self.assertIn("Copyright (c) 2026 Jason Perlow", text)
        self.assertIn("WITHOUT WARRANTY OF ANY KIND", text)

    def test_changelog_states_the_version_the_dependency_and_the_grammar(self):
        staging = self.render()
        raw = self.read(
            staging, "usr/share/doc/apple-t2-audio-config/changelog.Debian.gz"
        )
        self.assertEqual(raw[:2], b"\x1f\x8b")
        text = gzip.decompress(raw).decode("utf-8")
        self.assertIn("apple-t2-audio-config (0.5.1+ncz1)", text)
        self.assertIn("alsa-ucm-conf", text)
        self.assertIn("Syntax 6", text)
        self.assertIn("Jason Perlow", text)


class ModeAndOwnershipTests(GeneratorTestCase):
    def test_files_are_0644_and_directories_are_0755(self):
        staging = self.render()
        for base, directories, files in os.walk(staging):
            for name in directories:
                mode = os.stat(os.path.join(base, name)).st_mode & 0o7777
                self.assertEqual(mode, 0o755, os.path.join(base, name))
            for name in files:
                full = os.path.join(base, name)
                self.assertEqual(os.stat(full).st_mode & 0o7777, 0o644, full)

    def test_nothing_is_executable_or_group_or_world_writable(self):
        staging = self.render()
        for base, _dirs, files in os.walk(staging):
            for name in files:
                mode = os.stat(os.path.join(base, name)).st_mode & 0o7777
                self.assertEqual(mode & 0o111, 0, name)
                self.assertEqual(mode & 0o022, 0, name)


class RefusalTests(GeneratorTestCase):
    """Every refusal must happen before a byte or a directory is created."""

    def assert_refused(self, out_dir, needle=None, layout="all", validate_only=False):
        rc, err = self.run_generator(
            out_dir=out_dir, layout=layout, validate_only=validate_only
        )
        self.assertEqual(rc, 2, "expected refusal for %r (%s)" % (out_dir, err))
        self.assertIn("error", err)
        if needle:
            self.assertIn(needle, err)
        return err

    def test_relative_output_path_is_refused(self):
        self.assert_refused("relative/staging", "absolute")

    def test_parent_traversal_is_refused(self):
        self.assert_refused(self._tmp + "/../staging", "'..'")

    def test_root_and_system_paths_are_refused(self):
        for path in (
            "/",
            "/usr",
            "/usr/share/alsa/ucm2",
            "/etc",
            "/usr/share/alsa/ucm2/AppleT2",
        ):
            self.assert_refused(path, "refus")

    def test_symlinked_output_directory_is_refused(self):
        real = os.path.join(self._tmp, "real")
        os.makedirs(real)
        link = os.path.join(self._tmp, "link")
        os.symlink(real, link)
        self.assert_refused(link, "symlink")
        self.assertEqual(os.listdir(real), [])

    def test_non_empty_output_directory_is_refused_and_preserved(self):
        busy = os.path.join(self._tmp, "busy")
        os.makedirs(busy)
        with open(os.path.join(busy, "keep"), "w", encoding="utf-8") as handle:
            handle.write("x")
        self.assert_refused(busy, "not empty")
        self.assertEqual(os.listdir(busy), ["keep"])
        self.assertEqual(self.read(busy, "keep"), b"x")

    def test_output_directory_inside_the_source_tree_is_refused(self):
        target = os.path.join(PKG_DIR, "staging-must-not-appear")
        err = self.assert_refused(target, "outside the package source tree")
        self.assertFalse(os.path.exists(target), err)

    def test_unknown_layout_is_refused_before_writing(self):
        for requested in ("8", "x6", "0", "", "six", "-2"):
            target = os.path.join(self._tmp, "layout-%s" % (requested or "empty"))
            self.assert_refused(target, "unknown layout", layout=requested)
            self.assertFalse(os.path.exists(target), requested)

    def test_validate_only_writes_nothing(self):
        target = os.path.join(self._tmp, "validated-only")
        rc, err = self.run_generator(out_dir=target, validate_only=True)
        self.assertEqual(rc, 0, err)
        self.assertIn("nothing written", err)
        self.assertFalse(os.path.exists(target))

    def test_validate_only_also_refuses_a_bad_layout_and_a_bad_path(self):
        self.assert_refused(
            os.path.join(self._tmp, "v-layout"),
            "unknown layout",
            layout="8",
            validate_only=True,
        )
        self.assert_refused(
            os.path.join(PKG_DIR, "v-nope"),
            "outside the package source tree",
            validate_only=True,
        )

    def _mutated_facts(self, mutate):
        facts = load_facts()
        mutate(facts)
        path = os.path.join(self._tmp, "facts.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(facts, handle)
        return path

    def assert_facts_refused(self, mutate, needle):
        facts_path = self._mutated_facts(mutate)
        slug = "".join(char if char.isalnum() else "_" for char in needle)[:40]
        target = os.path.join(self._tmp, "staging-%s" % slug)
        rc, err = self.run_generator(out_dir=target, facts_path=facts_path)
        self.assertEqual(rc, 2, needle)
        self.assertIn(needle, err)
        self.assertFalse(os.path.exists(target), "wrote output for %s" % needle)

    def test_invalid_facts_are_refused_before_writing(self):
        cases = [
            (
                lambda f: f["speaker"]["channel_positions"].__setitem__(
                    "6", ["FL", "FR"]
                ),
                "expected 6 channel positions",
            ),
            (
                lambda f: f["speaker"].__setitem__("channels", [2, 4, 6, 8]),
                "channel_positions must have exactly",
            ),
            (
                lambda f: f["speaker"].__setitem__("format", "FLOAT_LE"),
                "not a plain sample format",
            ),
            (
                lambda f: f["speaker"].__setitem__("priority", "high"),
                "expected an integer",
            ),
            (
                lambda f: f["speaker"].__setitem__("preserve_all_channels", False),
                "preserve_all_channels",
            ),
            (
                lambda f: f["speaker"].__setitem__("app_channels", 2),
                "app_channels is gone",
            ),
            (
                lambda f: f["speaker"].__setitem__("shared_split_pcm_required", False),
                "shared_split_pcm_required",
            ),
            (
                lambda f: f["capture"][0].__setitem__("priority", -1),
                "priority out of range",
            ),
            (
                lambda f: f["capture"][0].__setitem__("conflict", "Nope"),
                "unknown conflict",
            ),
            (
                lambda f: f["capture"][0].__setitem__("pcm_device", 2),
                "reuses hardware PCM device",
            ),
            (
                lambda f: f["capture"][0].__setitem__("rate", [48000, 96000]),
                "pins exactly one",
            ),
            (
                lambda f: f["split"].__setitem__("macro_file", "/usr/local/split.conf"),
                "split.macro_file",
            ),
            (
                lambda f: f["split"].__setitem__("macro_instance", "bad name"),
                "bad UCM identifier",
            ),
            (
                lambda f: f["split"].__setitem__("split_pcm_macro", "@SplitPCM"),
                "bad UCM identifier",
            ),
            (
                lambda f: f["package"].__setitem__("version", "not a version"),
                "not a Debian version",
            ),
            (
                lambda f: f["package"].__setitem__("name", "apple-t2-audio"),
                "must stay apple-t2-audio-config",
            ),
            (
                lambda f: f["package"].__setitem__("depends", "libasound2"),
                "must name alsa-ucm-conf",
            ),
            (lambda f: f["ucm"].__setitem__("verb", "not a verb!"), "ucm.verb"),
            (
                lambda f: f["ucm"].__setitem__("syntax_version", 5),
                "ucm.syntax_version must be 6",
            ),
            (lambda f: f["ucm"].__setitem__("root", "/usr/share/alsa"), "ucm.root"),
            (
                lambda f: f.__setitem__("schema_version", 1),
                "unsupported facts schema_version",
            ),
        ]
        for mutate, needle in cases:
            self.assert_facts_refused(mutate, needle)

    def test_missing_facts_file_is_refused(self):
        target = os.path.join(self._tmp, "staging-missing-facts")
        rc, err = self.run_generator(
            out_dir=target, facts_path=os.path.join(self._tmp, "nope.json")
        )
        self.assertEqual(rc, 2)
        self.assertIn("cannot read facts file", err)
        self.assertFalse(os.path.exists(target))

    def test_missing_license_is_refused(self):
        empty_source = os.path.join(self._tmp, "empty-source")
        os.makedirs(empty_source)
        target = os.path.join(self._tmp, "staging-empty-source")
        rc, err = self.run_generator(out_dir=target, source_dir=empty_source)
        self.assertEqual(rc, 2)
        self.assertIn("cannot read LICENSE", err)
        self.assertFalse(os.path.exists(target))


class DeterminismTests(GeneratorTestCase):
    def test_two_renders_are_byte_identical(self):
        first = self.render(name="first")
        second = self.render(name="second")
        self.assertEqual(self.staged_files(first), self.staged_files(second))
        for path in self.staged_files(first):
            self.assertEqual(self.read(first, path), self.read(second, path), path)

    def test_gzip_changelog_carries_no_timestamp(self):
        staging = self.render()
        raw = self.read(
            staging, "usr/share/doc/apple-t2-audio-config/changelog.Debian.gz"
        )
        self.assertEqual(raw[:2], b"\x1f\x8b")
        self.assertEqual(raw[4:8], b"\x00\x00\x00\x00", "gzip MTIME is not zero")

    def test_files_carry_the_source_date_epoch(self):
        staging = self.render()
        epoch = gen.DEFAULT_SOURCE_DATE_EPOCH
        for path in self.staged_files(staging):
            self.assertEqual(
                int(os.stat(os.path.join(staging, path)).st_mtime), epoch, path
            )

    def test_a_different_epoch_only_moves_timestamps_and_the_changelog_date(self):
        first = self.render(name="epoch-default")
        second_root = os.path.join(self._tmp, "epoch-other")
        rc, err = self.run_generator(
            out_dir=second_root, epoch=gen.DEFAULT_SOURCE_DATE_EPOCH + 86400
        )
        self.assertEqual(rc, 0, err)
        differing = [
            path
            for path in self.staged_files(first)
            if self.read(first, path) != self.read(second_root, path)
        ]
        self.assertEqual(
            differing, ["usr/share/doc/apple-t2-audio-config/changelog.Debian.gz"]
        )


class BuildScriptTests(GeneratorTestCase):
    """Static checks plus real refusals; the success path runs --stage-only."""

    def setUp(self):
        super(BuildScriptTests, self).setUp()
        with open(BUILD_SCRIPT, "r", encoding="utf-8") as handle:
            self.script = handle.read()
        # the script compares the literal path with its physical form, so the
        # fake home has to be free of symbolic-link components itself
        real = os.path.realpath(self._tmp)
        self.home = os.path.join(real, "home")
        self.projects = os.path.join(self.home, "Projects")
        os.makedirs(self.projects)
        self.addCleanup(shutil.rmtree, self.home, ignore_errors=True)

    def run_script(self, *args):
        env = dict(os.environ)
        env["HOME"] = self.home
        return subprocess.run(
            ["bash", BUILD_SCRIPT, *args],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            env=env,
            check=False,
        )

    def output(self, name):
        return os.path.join(self.projects, name)

    def assert_refused_script(self, needle, *args):
        result = self.run_script(*args)
        text = result.stdout.decode("utf-8", "replace")
        self.assertEqual(result.returncode, 2, text)
        self.assertIn("error:", text)
        self.assertIn(needle, text)
        return text

    def test_build_script_is_syntactically_valid_bash(self):
        if shutil.which("bash") is None:  # pragma: no cover - supervisor runs on Linux
            self.skipTest("bash is not available")
        result = subprocess.run(
            ["bash", "-n", BUILD_SCRIPT],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout.decode("utf-8", "replace"))

    def test_missing_out_dir_is_refused(self):
        self.assert_refused_script(
            "--out-dir is required", "--scratch-parent", self.projects
        )

    def test_relative_out_dir_is_refused(self):
        self.assert_refused_script(
            "absolute", "--out-dir", "relative/out", "--scratch-parent", self.projects
        )

    def test_scratch_parent_outside_projects_is_refused(self):
        outside = os.path.join(os.path.realpath(self._tmp), "not-projects")
        os.makedirs(outside)
        self.assert_refused_script(
            "or below it", "--out-dir", self.output("out"), "--scratch-parent", outside
        )
        self.assertFalse(os.path.exists(os.path.join(self.projects, "out")))

    def test_scratch_parent_that_is_a_symlink_is_refused(self):
        link = os.path.join(self.projects, "link")
        os.symlink(os.path.realpath(self._tmp), link)
        self.assert_refused_script(
            "symbolic link",
            "--out-dir",
            self.output("out"),
            "--scratch-parent",
            link,
            "--stage-only",
        )

    def test_scratch_parent_overlapping_the_output_directory_is_refused(self):
        work = self.output("work")
        os.makedirs(work)
        self.assert_refused_script(
            "overlaps", "--out-dir", work, "--scratch-parent", work, "--stage-only"
        )
        self.assertEqual(os.listdir(work), [])

    def test_scratch_parent_at_the_source_tree_is_refused(self):
        self.assert_refused_script(
            "or below it",
            "--out-dir",
            self.output("out"),
            "--scratch-parent",
            PKG_DIR,
            "--stage-only",
        )
        self.assertFalse(os.path.exists(self.output("out")))

    def test_out_dir_inside_the_source_tree_is_refused(self):
        self.assert_refused_script(
            "overlaps",
            "--out-dir",
            os.path.join(PKG_DIR, "nope"),
            "--scratch-parent",
            self.projects,
            "--stage-only",
        )
        self.assertFalse(os.path.exists(os.path.join(PKG_DIR, "nope")))

    def test_non_empty_out_dir_is_refused_and_preserved(self):
        busy = self.output("busy")
        os.makedirs(busy)
        with open(os.path.join(busy, "keep"), "w", encoding="utf-8") as handle:
            handle.write("x")
        self.assert_refused_script(
            "not empty",
            "--out-dir",
            busy,
            "--scratch-parent",
            self.projects,
            "--stage-only",
        )
        self.assertEqual(os.listdir(busy), ["keep"])
        self.assertFalse(
            os.path.exists(
                os.path.join(busy, "apple-t2-audio-config_0.5.1+ncz1_all.deb")
            )
        )

    def test_unknown_layout_is_refused_before_anything_is_created(self):
        out = self.output("out-layout")
        self.assert_refused_script(
            "unknown layout",
            "--out-dir",
            out,
            "--scratch-parent",
            self.projects,
            "--layout",
            "8",
            "--stage-only",
        )
        self.assertFalse(os.path.exists(out))
        self.assertEqual(os.listdir(self.projects), [])

    def test_missing_out_dir_parent_is_refused_before_anything_is_created(self):
        out = self.output("missing/out")
        self.assert_refused_script(
            "parent of --out-dir",
            "--out-dir",
            out,
            "--scratch-parent",
            self.projects,
            "--stage-only",
        )
        self.assertEqual(os.listdir(self.projects), [])

    def test_unknown_argument_is_refused(self):
        self.assert_refused_script(
            "unknown argument",
            "--out-dir",
            self.output("out"),
            "--scratch-parent",
            self.projects,
            "--nope",
        )

    # -- success path ------------------------------------------------------

    def test_successful_stage_only_leaves_the_caller_directory_intact(self):
        marker = os.path.join(self.projects, "caller-owned")
        os.makedirs(marker)
        with open(os.path.join(marker, "keep.txt"), "w", encoding="utf-8") as handle:
            handle.write("do not delete me")
        result = self.run_script(
            "--out-dir",
            self.output("out"),
            "--scratch-parent",
            self.projects,
            "--stage-only",
        )
        text = result.stdout.decode("utf-8", "replace")
        self.assertEqual(result.returncode, 0, text)
        self.assertIn("stage-only", text)
        self.assertEqual(os.listdir(marker), ["keep.txt"])
        self.assertEqual(self.read(marker, "keep.txt"), b"do not delete me")
        # the .deb was not built and the output directory was not created
        self.assertFalse(os.path.exists(self.output("out")))

    def test_scratch_child_is_removed_on_exit_and_isolated_from_the_caller(self):
        marker = os.path.join(self.projects, "caller-owned")
        os.makedirs(marker)
        result = self.run_script(
            "--out-dir",
            self.output("out"),
            "--scratch-parent",
            self.projects,
            "--stage-only",
        )
        text = result.stdout.decode("utf-8", "replace")
        self.assertEqual(result.returncode, 0, text)
        self.assertEqual(sorted(os.listdir(self.projects)), ["caller-owned"])
        self.assertNotIn("scratch kept", text)

    def test_kept_staging_is_a_unique_child_inside_the_validated_parent(self):
        result = self.run_script(
            "--out-dir",
            self.output("out"),
            "--scratch-parent",
            self.projects,
            "--stage-only",
            "--keep-staging",
        )
        text = result.stdout.decode("utf-8", "replace")
        self.assertEqual(result.returncode, 0, text)
        children = os.listdir(self.projects)
        self.assertEqual(len(children), 1, children)
        child = children[0]
        self.assertTrue(child.startswith("apple-t2-audio-config.stage."), child)
        self.assertTrue(os.path.isdir(os.path.join(self.projects, child, "staging")))


if __name__ == "__main__":
    unittest.main(verbosity=2)
