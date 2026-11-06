#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jason Perlow
"""Deterministic generator for the data-only ``apple-t2-audio-config`` payload.

Writes the six UCM files the package provides - three ``Syntax 6`` card
configurations under ``conf.d/`` and the three ``HiFi-x<n>.conf`` use-case
master configurations they bind to - plus the ``DEBIAN/`` control data and the
shipped copyright/changelog, from the validated facts in ``facts.json``.
Nothing outside the caller's output directory is read or written, no network is
used, and the same inputs always produce byte-identical output (including the
gzip changelog, which is written with mtime 0).

The emitted text is real ALSA use-case manager syntax, version 6:

* the card file is ``Syntax 6`` + ``SectionUseCase."<verb>"`` whose ``File``
  value is the root-relative path of the master configuration this run
  actually generated for that layout;
* the master configuration pulls in the split-PCM macro interface shipped by
  ``alsa-ucm-conf`` with ``Include.<id>.File``, defines one shared speaker
  stream with ``Macro.<instance>.<Macro>`` and binds it to
  ``SectionDevice."<name>"`` with ``Macro.<instance>.<Macro>``;
* every route publishes its hardware stream through the real
  ``SectionDevice``/``Value`` keys (``PlaybackPCM``, ``PlaybackChannels``,
  ``PlaybackPriority``, ``CapturePCM``, ``CaptureChannels``, ``CaptureRate``,
  ``CapturePriority``, ``JackControl``, ``ConflictingDevice``).

No private or invented grammar is emitted: there is no ``SectionUCM``,
``SectionDev``, ``SectionPCM``, ``SectionPCMAuto``, ``Devices``/``Channels``/
``Priority``/``Jack`` pseudo-DSL, and no ``"key=value"`` macro arguments.

Design constraints this file exists to enforce:

* data only - no DSP/filter blocks, no speaker-protection blocks, no test
  sounds, no volume or mixer changes, no maintainer scripts, no
  PipeWire/WirePlumber payload;
* every physical speaker channel of a layout is preserved end to end - the
  application channel count equals the hardware channel count, and the channel
  map is the identity map over the layout's own channel positions. There is no
  stereo-only or front-pair projection;
* an invalid facts document, an unknown layout or an unsafe output path aborts
  *before* a single byte - or a single directory - is written;
* every payload file is 0644 and every directory 0755, root-owned after
  ``dpkg-deb --root-owner-group``;
* the source tree is never written to - the staging root is a caller-supplied
  directory outside it.

The generated UCM text is fresh work.  Only the *macro interface* of
alsa-ucm-conf is referenced (by path and macro name); no upstream T2 use-case
text was supplied to the primary author or copied here. The supervisor
extracted interface facts from the installed baseline. See ``../README.md``.
"""

from __future__ import annotations

import argparse
import gzip
import io
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PKG_DIR = os.path.dirname(HERE)
DEFAULT_FACTS = os.path.join(HERE, "facts.json")

DIR_MODE = 0o755
FILE_MODE = 0o644
SCHEMA_VERSION = 2
# 2026-10-15T00:00:00Z - the pinned reference date for this release line.
DEFAULT_SOURCE_DATE_EPOCH = 1792022400

NAME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_.-]*$")
ID_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]*$")
POSITION_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")
VERSION_RE = re.compile(r"^[0-9][A-Za-z0-9.+~:-]*$")
FORMAT_RE = re.compile(r"^S(8|16|24|32)_(LE|BE)$")
DEPENDS_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9+.-]*( \([^()]+\))?(, .*)?$")
POSITION_NAMES = {
    "MONO",
    "FL",
    "FR",
    "FC",
    "LFE",
    "SL",
    "SR",
    "RL",
    "RR",
    "RC",
    "FLC",
    "FRC",
    "BC",
    "TC",
    "TFL",
    "TFC",
    "TFR",
    "TBL",
    "TBC",
    "TBR",
    "TSL",
    "TSR",
}

# Never a legitimate generation target.
DENY_OUT_DIRS = frozenset(
    [
        "/",
        "/usr",
        "/usr/share",
        "/usr/share/alsa",
        "/usr/share/alsa/ucm2",
        "/usr/share/alsa/ucm2/common",
        "/usr/share/alsa/ucm2/conf.d",
        "/usr/share/alsa/ucm2/AppleT2",
        "/etc",
        "/var",
        "/home",
        "/root",
        "/boot",
        "/opt",
        "/srv",
        "/media",
        "/mnt",
        "/lib",
        "/lib64",
        "/bin",
        "/sbin",
        "/dev",
        "/proc",
        "/sys",
    ]
)

_DAYS = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
_MONTHS = (
    "Jan",
    "Feb",
    "Mar",
    "Apr",
    "May",
    "Jun",
    "Jul",
    "Aug",
    "Sep",
    "Oct",
    "Nov",
    "Dec",
)

ALSA_NOTICE = (
    "alsa-ucm-conf (common/pcm/split.conf macro interface)\n"
    "  Copyright (c) 2019, Advanced Linux Sound Architecture (ALSA) project\n"
    "  All rights reserved.\n"
    "  Licensed under the BSD 3-Clause License. This package does not vendor\n"
    "  or redistribute that file; it only references its path and macro names\n"
    "  and depends on the alsa-ucm-conf package, which ships it.\n"
)


class GeneratorError(Exception):
    """Any refusal: bad input, unsafe target, unreadable source."""


# --------------------------------------------------------------------------
# facts loading and validation
# --------------------------------------------------------------------------


def load_facts(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            facts = json.load(handle)
    except OSError as exc:
        raise GeneratorError("cannot read facts file %s: %s" % (path, exc))
    except ValueError as exc:
        raise GeneratorError("facts file %s is not valid JSON: %s" % (path, exc))
    if not isinstance(facts, dict):
        raise GeneratorError("facts file %s must contain a JSON object" % path)
    return facts


def _require(condition, message):
    if not condition:
        raise GeneratorError(message)


def _as_int(value, message):
    if isinstance(value, bool) or not isinstance(value, int):
        raise GeneratorError("%s: expected an integer, got %r" % (message, value))
    return value


def _as_name(value, message):
    _require(
        isinstance(value, str) and NAME_RE.match(value),
        "%s: bad name %r" % (message, value),
    )
    return value


def _as_id(value, message):
    _require(
        isinstance(value, str) and ID_RE.match(value),
        "%s: bad UCM identifier %r" % (message, value),
    )
    return value


def _validate_device(device, kind, used_names, used_devices):
    name = _as_name(device.get("name"), "%s device name" % kind)
    _require(name not in used_names, "%s device %r is declared twice" % (kind, name))
    used_names.add(name)
    pcm_device = _as_int(device.get("pcm_device"), "%s %s pcm_device" % (kind, name))
    _require(pcm_device >= 0, "%s %s pcm_device must be >= 0" % (kind, name))
    _require(
        pcm_device not in used_devices,
        "%s %s reuses hardware PCM device %d" % (kind, name, pcm_device),
    )
    used_devices.add(pcm_device)
    channels = _as_int(device.get("channels"), "%s %s channels" % (kind, name))
    _require(channels >= 1, "%s %s must have at least one channel" % (kind, name))
    priority = _as_int(device.get("priority"), "%s %s priority" % (kind, name))
    _require(0 <= priority <= 10000, "%s %s priority out of range" % (kind, name))
    if "jack" in device:
        jack = device["jack"]
        _require(
            isinstance(jack, str) and jack.strip() != "",
            "%s %s jack must be a non-empty string" % (kind, name),
        )
    if "rate" in device:
        rate = device["rate"]
        _require(
            isinstance(rate, list) and rate, "%s %s rate must be a list" % (kind, name)
        )
        _require(
            len(rate) == 1,
            "%s %s declares %d rates; this hardware pins exactly one"
            % (kind, name, len(rate)),
        )
        for value in rate:
            _as_int(value, "%s %s rate" % (kind, name))
            _require(value > 0, "%s %s rate must be positive" % (kind, name))
    return name


def validate_facts(facts):
    """Validate the facts document; raise GeneratorError on anything odd.

    Called before the filesystem is touched so an invalid input cannot leave a
    half-written staging tree - or an empty output directory - behind.
    """
    _require(
        facts.get("schema_version") == SCHEMA_VERSION,
        "unsupported facts schema_version %r (expected %d)"
        % (facts.get("schema_version"), SCHEMA_VERSION),
    )

    package = facts.get("package")
    _require(isinstance(package, dict), "facts.package missing")
    _require(
        package.get("name") == "apple-t2-audio-config",
        "package name must stay apple-t2-audio-config so apt upgrades in place",
    )
    _require(
        isinstance(package.get("version"), str)
        and VERSION_RE.match(package["version"]),
        "package.version %r is not a Debian version" % (package.get("version"),),
    )
    _require(package.get("architecture") == "all", "package.architecture must be 'all'")
    depends = package.get("depends")
    _require(
        isinstance(depends, str) and DEPENDS_RE.match(depends),
        "package.depends %r is not a Debian dependency field" % (depends,),
    )
    _require(
        "alsa-ucm-conf" in depends,
        "package.depends must name alsa-ucm-conf (it ships common/pcm/split.conf)",
    )

    ucm = facts.get("ucm")
    _require(isinstance(ucm, dict), "facts.ucm missing")
    _as_name(ucm.get("driver_dir"), "ucm.driver_dir")
    _as_name(ucm.get("conf_d_dir"), "ucm.conf_d_dir")
    _as_name(ucm.get("verb"), "ucm.verb")
    root = ucm.get("root")
    _require(
        isinstance(root, str) and root.startswith("/") and root.endswith("/ucm2"),
        "ucm.root must be an absolute .../ucm2 path",
    )
    _require(
        ucm.get("syntax_version") == 6,
        "ucm.syntax_version must be 6 (the ucm2 card/use case syntax)",
    )
    for key in ("card_name_template", "master_config_template"):
        value = ucm.get(key)
        _require(
            isinstance(value, str) and "{n}" in value and "/" not in value,
            "ucm.%s must be a single name component holding {n}" % key,
        )

    split = facts.get("split")
    _require(isinstance(split, dict), "facts.split missing")
    macro_file = split.get("macro_file")
    _require(
        isinstance(macro_file, str)
        and macro_file.startswith("/common/pcm/")
        and macro_file.endswith(".conf"),
        "split.macro_file must be a root-relative /common/pcm/*.conf macro file",
    )
    _as_id(split.get("include_id"), "split.include_id")
    _as_id(split.get("macro_instance"), "split.macro_instance")
    for key in ("split_pcm_macro", "split_pcm_device_macro"):
        _as_id(split.get(key), "split.%s" % key)
    _require(
        split["split_pcm_macro"] != split["split_pcm_device_macro"],
        "split.split_pcm_macro and split.split_pcm_device_macro must differ",
    )
    _as_name(split.get("substi_name"), "split.substi_name")

    speaker = facts.get("speaker")
    _require(isinstance(speaker, dict), "facts.speaker missing")
    speaker_name = _as_name(speaker.get("name"), "speaker.name")
    layouts = speaker.get("channels")
    _require(
        isinstance(layouts, list)
        and layouts
        and all(
            isinstance(item, int) and not isinstance(item, bool) and item >= 2
            for item in layouts
        ),
        "speaker.channels must be a list of integers >= 2",
    )
    _require(
        layouts == sorted(layouts) and len(set(layouts)) == len(layouts),
        "speaker.channels must be sorted and unique",
    )
    positions = speaker.get("channel_positions")
    _require(isinstance(positions, dict), "speaker.channel_positions missing")
    _require(
        sorted(positions.keys(), key=int) == sorted((str(n) for n in layouts), key=int),
        "speaker.channel_positions must have exactly the speaker.channels layouts",
    )
    for layout in layouts:
        pos_list = positions[str(layout)]
        _require(
            isinstance(pos_list, list) and len(pos_list) == layout,
            "layout %s: expected %d channel positions" % (layout, layout),
        )
        for position in pos_list:
            _require(
                isinstance(position, str) and POSITION_RE.match(position),
                "layout %s: bad channel position %r" % (layout, position),
            )
            _require(
                position in POSITION_NAMES,
                "layout %s: unknown ALSA channel position %r" % (layout, position),
            )
        _require(
            len(set(pos_list)) == len(pos_list),
            "layout %s: duplicate channel position" % layout,
        )
    speaker_format = speaker.get("format")
    _require(
        isinstance(speaker_format, str) and FORMAT_RE.match(speaker_format),
        "speaker.format %r is not a plain sample format" % (speaker_format,),
    )
    speaker_priority = _as_int(speaker.get("priority"), "speaker.priority")
    _require(0 <= speaker_priority <= 10000, "speaker.priority out of range")
    _require(
        "app_channels" not in speaker,
        "speaker.app_channels is gone: the speaker must present every "
        "hardware channel of the layout, not a projected stereo pair",
    )
    _require(
        speaker.get("preserve_all_channels") is True,
        "speaker.preserve_all_channels must be true for this hardware",
    )
    _require(
        speaker.get("shared_split_pcm_required") is True,
        "speaker.shared_split_pcm_required must be true for this hardware",
    )

    used_names = {speaker_name}
    used_devices = set()
    speaker_device = _as_int(speaker.get("pcm_device"), "speaker.pcm_device")
    _require(speaker_device >= 0, "speaker.pcm_device must be >= 0")
    used_devices.add(speaker_device)

    for kind in ("playback", "capture"):
        devices = facts.get(kind)
        _require(
            isinstance(devices, list) and devices,
            "facts.%s must be a non-empty list of devices" % kind,
        )
        for device in devices:
            _require(
                isinstance(device, dict), "%s device entries must be objects" % kind
            )
            _validate_device(device, kind, used_names, used_devices)

    for kind in ("playback", "capture"):
        for device in facts[kind]:
            conflict = device.get("conflict")
            if conflict is None:
                continue
            _require(
                isinstance(conflict, str) and conflict in used_names,
                "%s device %r declares unknown conflict %r"
                % (kind, device["name"], conflict),
            )
            _require(
                conflict != device["name"],
                "%s device %r must not conflict with itself" % (kind, device["name"]),
            )

    for path in facts.get("untouched_paths", []):
        _require(
            isinstance(path, str) and path.startswith("/"),
            "untouched_paths entries must be absolute",
        )
    return facts


def select_layouts(requested, facts):
    available = list(facts["speaker"]["channels"])
    if requested == "all":
        return available
    if requested.isdigit() and int(requested) in available:
        return [int(requested)]
    raise GeneratorError(
        "unknown layout %r; known layouts: %s"
        % (requested, ", ".join(str(item) for item in available))
    )


# --------------------------------------------------------------------------
# UCM path arithmetic - one source of truth for what is generated
# --------------------------------------------------------------------------


def card_name(facts, layout):
    return facts["ucm"]["card_name_template"].replace("{n}", str(layout))


def master_config_name(facts, layout):
    return facts["ucm"]["master_config_template"].replace("{n}", str(layout))


def master_config_link(facts, layout):
    """The value the card file's ``SectionUseCase`` File keyword carries.

    Root-relative, which is how a ``conf.d`` card configuration names the use
    case master configuration it binds to.
    """
    return "/%s/%s" % (facts["ucm"]["driver_dir"], master_config_name(facts, layout))


def master_config_payload_path(facts, layout):
    """Staging-relative path the use case master configuration is written to."""
    return "%s/%s" % (
        facts["ucm"]["root"].lstrip("/"),
        master_config_link(facts, layout).lstrip("/"),
    )


def card_config_payload_path(facts, layout):
    """Staging-relative path the card configuration is written to."""
    root = facts["ucm"]["root"].lstrip("/")
    card = card_name(facts, layout)
    return "%s/%s/%s/%s.conf" % (root, facts["ucm"]["conf_d_dir"], card, card)


def channel_positions(facts, layout):
    return list(facts["speaker"]["channel_positions"][str(layout)])


# --------------------------------------------------------------------------
# UCM rendering
# --------------------------------------------------------------------------


def _indent(level):
    return "\t" * level


def _header(title, lines):
    out = [
        "# NCZ-OS package apple-t2-audio-config - GENERATED, DO NOT EDIT BY HAND.",
        "# Regenerate with packages/apple-t2-audio-config/build-deb.sh.",
        "#",
    ]
    out.extend("# " + line if line else "#" for line in lines)
    out.append("#")
    out.append("# " + title)
    out.append("#")
    out.append("# Written from observed ALSA interface facts. Provenance and the")
    out.append("# independent-implementation boundary:")
    out.append("# packages/apple-t2-audio-config/README.md")
    return out


def _split_pcm_macro(facts, layout):
    """The shared speaker stream definition - every hardware channel kept."""
    split = facts["split"]
    speaker = facts["speaker"]
    positions = channel_positions(facts, layout)
    lines = [
        "Macro.%s.%s {" % (split["macro_instance"], split["split_pcm_macro"]),
        _indent(1) + 'Name "%s"' % split["substi_name"],
        _indent(1) + "Direction Playback",
        _indent(1) + "Format %s" % speaker["format"],
        _indent(1) + "Channels %d" % layout,
        _indent(1) + "HWChannels %d" % layout,
    ]
    for index, position in enumerate(positions):
        lines.append(_indent(1) + "HWChannelPos%d %s" % (index, position))
    lines.append("}")
    return lines


def _split_pcm_device_macro(facts, layout):
    """Bind the shared stream to the speaker device, channel for channel."""
    split = facts["split"]
    speaker = facts["speaker"]
    positions = channel_positions(facts, layout)
    lines = [
        "Macro.%s.%s {" % (split["macro_instance"], split["split_pcm_device_macro"]),
        _indent(1) + 'Name "%s"' % split["substi_name"],
        _indent(1) + "Direction Playback",
        _indent(1) + "Device %d" % speaker["pcm_device"],
        _indent(1) + "Channels %d" % layout,
        _indent(1) + "HWChannels %d" % layout,
    ]
    for index, position in enumerate(positions):
        lines.append(_indent(1) + "Channel%d %d" % (index, index))
        lines.append(_indent(1) + "ChannelPos%d %s" % (index, position))
    lines.append("}")
    return lines


def _device_value_block(device, direction, level):
    """The real SectionDevice/Value keys for one hardware route."""
    pad = _indent(level)
    prefix = "Playback" if direction == "Playback" else "Capture"
    keys = [
        '%sPCM "hw:${CardId},%d"' % (prefix, device["pcm_device"]),
        "%sChannels %d" % (prefix, device["channels"]),
    ]
    if direction == "Capture" and "rate" in device:
        keys.append("%sRate %d" % (prefix, device["rate"][0]))
    keys.append("%sPriority %d" % (prefix, device["priority"]))
    if "jack" in device:
        keys.append('JackControl "%s"' % device["jack"])
    lines = [pad + "Value {"]
    lines.extend(_indent(level + 1) + key for key in keys)
    lines.append(pad + "}")
    return lines


def render_master_conf(facts, layout):
    """Render the ``HiFi-x<n>.conf`` use case master configuration."""
    card = card_name(facts, layout)
    split = facts["split"]
    speaker = facts["speaker"]
    positions = channel_positions(facts, layout)
    lines = _header(
        "Use case configuration: %s, %d-channel speaker layout." % (card, layout),
        [
            "Reached from %s" % (card_config_payload_path(facts, layout),),
            "through SectionUseCase.%s." % facts["ucm"]["verb"],
            "Hardware PCM map on this card: 0 speaker, 1 digital microphone,",
            "2 codec line output, 3 codec line input.",
            "Speaker channel positions here: %s." % " ".join(positions),
        ],
    )
    lines.append("")
    lines.append("# Split-PCM macro interface, shipped by the alsa-ucm-conf package")
    lines.append("# (BSD 3-Clause, ALSA project) which this package depends on.")
    lines.append('Include.%s.File "%s"' % (split["include_id"], split["macro_file"]))
    lines.append("")
    lines.extend(_split_pcm_macro(facts, layout))
    lines.append("")
    lines.extend(["SectionVerb {", "\tValue {", '\t\tTQ "HiFi"', "\t}", "}"])
    lines.append("")
    lines.append('SectionDevice."%s" {' % speaker["name"])
    lines.append(
        _indent(1) + 'Comment "Internal speaker; all %d hardware channels."' % layout
    )

    lines.append(_indent(1) + "Value {")
    lines.append(_indent(2) + "PlaybackPriority %d" % speaker["priority"])
    lines.append(_indent(1) + "}")
    lines.extend(_split_pcm_device_macro(facts, layout))
    lines.append("}")
    for device in facts["playback"]:
        lines.append("")
        lines.append('SectionDevice."%s" {' % device["name"])
        lines.append(
            _indent(1)
            + 'Comment "%s; takes over from the speaker while plugged in."'
            % (
                "Headphone jack output"
                if device["name"] == "Headphones"
                else "Codec line output"
            )
        )
        if "conflict" in device:
            lines.append('\tConflictingDevice [ "%s" ]' % device["conflict"])
        lines.extend(_device_value_block(device, "Playback", 1))
        lines.append("}")
    for device in facts["capture"]:
        lines.append("")
        lines.append('SectionDevice."%s" {' % device["name"])
        lines.append(
            _indent(1)
            + 'Comment "%s."'
            % (
                "Digital microphone array"
                if device["name"] == "Mic"
                else "Headset microphone on the codec input"
            )
        )
        if "conflict" in device:
            lines.append('\tConflictingDevice [ "%s" ]' % device["conflict"])
        lines.extend(_device_value_block(device, "Capture", 1))
        lines.append("}")
    return "\n".join(lines) + "\n"


def render_card_conf(facts, layout):
    """Render the ``conf.d`` card file that binds this card name to the verb."""
    card = card_name(facts, layout)
    link = master_config_link(facts, layout)
    lines = _header(
        "Card configuration: the ALSA card name %s." % card,
        [
            "Syntax %d; the use case below is read from"
            % facts["ucm"]["syntax_version"],
            "%s, which this package generates for the" % link,
            "%d-channel layout of this card." % layout,
        ],
    )
    lines.append("Syntax %d" % facts["ucm"]["syntax_version"])
    lines.append("")
    lines.append('SectionUseCase."%s" {' % facts["ucm"]["verb"])
    lines.append(_indent(1) + 'File "%s"' % link)
    lines.append(
        _indent(1) + 'Comment "%s, %d-channel speaker layout."' % (card, layout)
    )
    lines.append("}")
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------
# Debian metadata
# --------------------------------------------------------------------------


def rfc2822(epoch):
    stamp = time.gmtime(epoch)
    return "%s, %02d %s %04d %02d:%02d:%02d +0000" % (
        _DAYS[stamp.tm_wday],
        stamp.tm_mday,
        _MONTHS[stamp.tm_mon - 1],
        stamp.tm_year,
        stamp.tm_hour,
        stamp.tm_min,
        stamp.tm_sec,
    )


def render_control(facts, installed_size_kib):
    package = facts["package"]
    description = [
        "ALSA use-case configurations for the Apple T2 audio codec (NCZ-OS)",
        " Fresh, data-only ALSA UCM Syntax 6 configurations for the HiFi verb",
        " on the AppleT2x2, AppleT2x4 and AppleT2x6 cards. Each card file binds",
        " its verb to the matching use case file; the use case describes the",
        " speaker stream split from one multichannel hardware PCM, the",
        " headphone output and headset microphone behind the codec output jack,",
        " and the digital microphone. No DSP, no WirePlumber or PipeWire",
        " configuration, no mixer or volume changes.",
        " .",
        " This replaces the payload of the previous 0.5.1 package and keeps the",
        " same package name and file paths, so apt upgrades in place without",
        " removing files. The SplitPCM and SplitPCMDevice macros come from",
        " alsa-ucm-conf, which this package depends on.",
    ]
    lines = [
        "Package: %s" % package["name"],
        "Version: %s" % package["version"],
        "Architecture: %s" % package["architecture"],
        "Maintainer: %s" % package["maintainer"],
        "Installed-Size: %d" % installed_size_kib,
        "Depends: %s" % package["depends"],
        "Section: %s" % package["section"],
        "Priority: %s" % package["priority"],
        "Homepage: %s" % package["homepage"],
        "Description: %s" % description[0],
    ]
    lines.extend(description[1:])
    return "\n".join(lines) + "\n"


def render_changelog(facts, epoch):
    package = facts["package"]
    return "\n".join(
        [
            "%s (%s) unstable; urgency=medium" % (package["name"], package["version"]),
            "",
            "  * The six payload files are real ALSA UCM Syntax 6 files: three",
            "    conf.d card configurations, each binding its verb to one of the",
            "    three HiFi use case files this package generates, replacing a",
            "    payload that was not in ALSA configuration syntax at all.",
            "  * Every route publishes its hardware stream through the standard",
            "    SectionDevice/Value keys, and the speaker stream is defined once",
            "    with the SplitPCM macro and bound with SplitPCMDevice.",
            "  * The speaker keeps all of the hardware channels of the layout",
            "    (x2, x4 and x6) instead of projecting a stereo pair out of them.",
            "  * Depends explicitly on alsa-ucm-conf for the common/pcm/split.conf",
            "    macro interface, which was missing on the observed targets.",
            "  * No DSP, no speaker-protection or WirePlumber payload, no test",
            "    sounds and no volume changes. /etc/pipewire/pipewire.conf.d/",
            "    99-ncz-audio-headroom.conf is not touched.",
            "  * No maintainer scripts: installing or upgrading restarts nothing.",
            "",
            " -- %s  %s" % (package["maintainer"], rfc2822(epoch)),
            "",
        ]
    )


def render_copyright(facts, license_text):
    return (
        "Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/\n"
        "Upstream-Name: apple-t2-audio-config (NCZ-OS)\n"
        "Source: https://github.com/ncz-os/cix-installer\n"
        "\n"
        "Files: *\n"
        "Copyright: 2026 Jason Perlow\n"
        "License: MIT\n"
        " The generator, the generated UCM files, the packaging scripts and the\n"
        " tests in this package are original work of Jason Perlow and are used\n"
        " under the MIT License; the full text follows.\n"
        "\n" + license_text.rstrip("\n") + "\n"
        "\n"
        "Files: debian/*\n"
        "Copyright: 2026 Jason Perlow\n"
        "License: MIT\n"
        "\n" + ALSA_NOTICE + "\n"
        "Third-party material NOT included: this package contains no DSP,\n"
        "speaker-protection or WirePlumber payload and no third-party\n"
        "use-case configuration text.\n"
    )


# --------------------------------------------------------------------------
# payload assembly and staging
# --------------------------------------------------------------------------


def build_payload(facts, layouts, license_text, epoch):
    """Return ``[(relative path, bytes)]`` for the whole staging tree."""
    payload = []
    for layout in layouts:
        payload.append(
            (
                master_config_payload_path(facts, layout),
                render_master_conf(facts, layout).encode("utf-8"),
            )
        )
        payload.append(
            (
                card_config_payload_path(facts, layout),
                render_card_conf(facts, layout).encode("utf-8"),
            )
        )

    doc_dir = "usr/share/doc/%s" % facts["package"]["name"]
    payload.append(
        (
            "%s/copyright" % doc_dir,
            render_copyright(facts, license_text).encode("utf-8"),
        )
    )
    payload.append(
        (
            "%s/changelog.Debian.gz" % doc_dir,
            gzip_bytes(render_changelog(facts, epoch).encode("utf-8")),
        )
    )
    payload_bytes = sum(
        len(data) for path, data in payload if not path.startswith("DEBIAN/")
    )
    installed_size_kib = (payload_bytes + 1023) // 1024

    payload.append(
        ("DEBIAN/control", render_control(facts, installed_size_kib).encode("utf-8"))
    )
    payload.append(
        ("DEBIAN/copyright", render_copyright(facts, license_text).encode("utf-8"))
    )
    return payload


def gzip_bytes(data):
    """Deterministic gzip container: no name, mtime 0, fixed compression level."""
    buffer = io.BytesIO()
    with gzip.GzipFile(
        filename="", mode="wb", fileobj=buffer, compresslevel=9, mtime=0
    ) as handle:
        handle.write(data)
    return buffer.getvalue()


def safe_out_dir(raw, source_dir):
    """Validate the caller's output directory. Raises GeneratorError."""
    if not raw:
        raise GeneratorError("--out-dir is required")
    if not os.path.isabs(raw):
        raise GeneratorError("--out-dir must be an absolute path, got %r" % raw)
    if ".." in raw.split(os.sep):
        raise GeneratorError("--out-dir must not contain '..' segments, got %r" % raw)
    normalised = os.path.normpath(raw)
    if os.path.islink(normalised):
        raise GeneratorError("--out-dir must not be a symlink: %s" % normalised)
    if normalised in DENY_OUT_DIRS or normalised == "/":
        raise GeneratorError("refusing to use %s as an output directory" % normalised)
    source = os.path.normpath(os.path.abspath(source_dir))
    if normalised == source or normalised.startswith(source + os.sep):
        raise GeneratorError(
            "--out-dir must be outside the package source tree (%s)" % source
        )
    if os.path.exists(normalised):
        if not os.path.isdir(normalised):
            raise GeneratorError(
                "--out-dir exists and is not a directory: %s" % normalised
            )
        if os.listdir(normalised):
            raise GeneratorError("--out-dir is not empty: %s" % normalised)
    return normalised


def _directories(paths):
    directories = set()
    for path in paths:
        parts = path.split("/")[:-1]
        for index in range(1, len(parts) + 1):
            directories.add("/".join(parts[:index]))
    return sorted(directories)


def stage(out_dir, payload, epoch):
    """Write the payload below ``out_dir``; return a sorted manifest."""
    manifest = []
    for relative in _directories([path for path, _ in payload]):
        full = os.path.join(out_dir, relative)
        os.makedirs(full, mode=DIR_MODE, exist_ok=True)
    for path, data in payload:
        full = os.path.join(out_dir, path)
        with open(full, "wb") as handle:
            handle.write(data)
        os.chmod(full, FILE_MODE)
        manifest.append({"path": path, "mode": "%04o" % FILE_MODE})
    for relative in _directories([path for path, _ in payload]):
        full = os.path.join(out_dir, relative)
        os.chmod(full, DIR_MODE)
        os.utime(full, (epoch, epoch))
    for entry in manifest:
        os.utime(os.path.join(out_dir, entry["path"]), (epoch, epoch))
    manifest.sort(key=lambda entry: entry["path"])
    return manifest


def read_license(source_dir):
    license_path = os.path.join(source_dir, "LICENSE")
    try:
        with open(license_path, "r", encoding="utf-8") as handle:
            license_text = handle.read()
    except OSError as exc:
        raise GeneratorError("cannot read LICENSE from %s: %s" % (license_path, exc))
    if "Jason Perlow" not in license_text or "MIT License" not in license_text:
        raise GeneratorError(
            "LICENSE at %s is not the expected MIT text" % license_path
        )
    return license_text


def render(out_dir, facts_path, source_dir, requested_layout, epoch):
    """Validate everything, then write. Returns (out_dir, manifest)."""
    facts = validate_facts(load_facts(facts_path))
    layouts = select_layouts(requested_layout, facts)
    target = safe_out_dir(out_dir, source_dir)
    license_text = read_license(source_dir)
    payload = build_payload(facts, layouts, license_text, epoch)
    manifest = stage(target, payload, epoch)
    return target, manifest


def validate_only(out_dir, facts_path, source_dir, requested_layout):
    """Validate arguments, facts and the output path; create nothing."""
    facts = validate_facts(load_facts(facts_path))
    select_layouts(requested_layout, facts)
    safe_out_dir(out_dir, source_dir)
    read_license(source_dir)
    return facts


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="applet2_ucm.py",
        description="Generate the data-only apple-t2-audio-config staging tree.",
    )
    parser.add_argument(
        "--facts", default=DEFAULT_FACTS, help="facts JSON (default: src/facts.json)"
    )
    parser.add_argument(
        "--out-dir", required=True, help="absolute, empty staging directory"
    )
    parser.add_argument(
        "--source-dir", default=PKG_DIR, help="package source directory (for LICENSE)"
    )
    parser.add_argument(
        "--layout", default="all", help="'all' or one of the known channel counts"
    )
    parser.add_argument(
        "--source-date-epoch",
        type=int,
        default=DEFAULT_SOURCE_DATE_EPOCH,
        help="timestamp for generated files and the changelog date",
    )
    parser.add_argument(
        "--validate-only",
        action="store_true",
        help="check arguments, facts and the output path, then write nothing",
    )
    parser.add_argument(
        "--json", action="store_true", help="print the manifest as JSON"
    )
    args = parser.parse_args(argv)

    try:
        if args.validate_only:
            validate_only(args.out_dir, args.facts, args.source_dir, args.layout)
            if args.json:
                sys.stdout.write(
                    json.dumps(
                        {"out_dir": os.path.normpath(args.out_dir), "validated": True}
                    )
                    + "\n"
                )
            else:
                sys.stdout.write(
                    "apple-t2-audio-config: arguments, facts and output path "
                    "validated; nothing written\n"
                )
            return 0
        out_dir, manifest = render(
            args.out_dir,
            args.facts,
            args.source_dir,
            args.layout,
            args.source_date_epoch,
        )
    except GeneratorError as exc:
        sys.stderr.write("apple-t2-audio-config: error: %s\n" % exc)
        return 2
    except OSError as exc:
        sys.stderr.write("apple-t2-audio-config: error: %s\n" % exc)
        return 2

    if args.json:
        sys.stdout.write(
            json.dumps({"out_dir": out_dir, "files": manifest}, indent=2) + "\n"
        )
    else:
        sys.stdout.write(
            "%s: %d files staged below %s\n" % (args.layout, len(manifest), out_dir)
        )
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
