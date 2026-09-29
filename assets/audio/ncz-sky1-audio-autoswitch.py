#!/usr/bin/env python3
"""Auto-route CIX Sky1 audio: HDMI/DP with a live ELD, else the HDA analog out.

Policy (board agnostic; O6N has only the 3 DP links, MS-R1 also has the
cix-ipbloq-hda ALC269 analog/digital card):
  1. a cix,sky1 DP/HDMI PCM whose ELD reports audio (sad_count > 0) wins;
  2. else the analog PCM of a cix-ipbloq-hda card. WirePlumber marks its
     profiles unavailable while the line-out jack reads unplugged, so it would
     create no sink at all; we deliberately create one anyway (powered speakers
     without jack sensing, or a plug inserted later, then just work). The
     price is that an unplugged line-out is a silent default, not "no sink";
  (several connected monitors: the lowest PCM index wins, kept while current)
  3. else nothing: leave PipeWire's own default alone.
`--decide [--proc-root DIR]` prints the decision without touching PipeWire.

This is deliberately a user-session helper instead of a PipeWire static
drop-in. If PipeWire Pulse rejects a module load, this process logs and keeps
running; it does not participate in pipewire.service startup.
"""

from __future__ import annotations

import glob
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path


POLL_SECONDS = 2.0
SINK_PREFIX = "ncz_sky1_hdmi"
ANALOG_PREFIX = "ncz_sky1_analog"
PROC = Path(os.environ.get("NCZ_SKY1_PROC_ROOT", "/proc/asound"))
OWN_PREFIXES = (SINK_PREFIX, ANALOG_PREFIX)


@dataclass(frozen=True)
class EldState:
    card: int
    device: int
    connection_type: str
    monitor_name: str
    sad_count: int

    @property
    def connected(self) -> bool:
        return self.sad_count > 0

    @property
    def sink_name(self) -> str:
        return f"{SINK_PREFIX}_{self.card}_{self.device}"


def run(argv: list[str], check: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        argv,
        check=check,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def log(message: str) -> None:
    print(f"ncz-sky1-audio-autoswitch: {message}", file=sys.stderr, flush=True)


def cix_cards() -> list[int]:
    cards = PROC / "cards"
    if not cards.exists():
        return []

    found: list[int] = []
    for line in cards.read_text(errors="replace").splitlines():
        match = re.match(r"\s*(\d+)\s+\[[^]]+\]:\s+([^ ]+)\s+-\s+(.*)$", line)
        if not match:
            continue
        card = int(match.group(1))
        text = f"{match.group(2)} {match.group(3)}".lower()
        if "cix,sky1" in text or "cix_sky1" in text or "cixsky1" in text:
            found.append(card)
    return found


def hda_cards() -> list[int]:
    cards = PROC / "cards"
    if not cards.exists():
        return []
    found: list[int] = []
    for line in cards.read_text(errors="replace").splitlines():
        match = re.match(r"\s*(\d+)\s+\[[^]]+\]:\s+([^ ]+)\s+-\s+(.*)$", line)
        if not match:
            continue
        text = f"{match.group(2)} {match.group(3)}".lower()
        if "cix-ipbloq-hda" in text or "cixipbloqhda" in text:
            found.append(int(match.group(1)))
    return found


def analog_device(card: int) -> int | None:
    """Playback PCM index of the analog output: the first pcmNp whose info names it Analog, else None."""
    devs = sorted(
        int(m.group(1))
        for m in (re.search(r"pcm(\d+)p$", str(p)) for p in glob.glob(f"{PROC}/card{card}/pcm*p"))
        if m
    )
    if not devs:
        return None
    for dev in devs:
        info = PROC / f"card{card}" / f"pcm{dev}p" / "info"
        try:
            if "analog" in info.read_text(errors="replace").lower():
                return dev
        except OSError:
            pass
    return None  # never guess: a non-analog first PCM may be digital/SPDIF


def parse_eld(path: Path) -> EldState | None:
    match = re.search(r"/card(\d+)/eld#(\d+)$", str(path))
    if not match:
        return None

    values: dict[str, str] = {}
    for raw in path.read_text(errors="replace").splitlines():
        if "\t" in raw:
            key, value = raw.split("\t", 1)
        elif " " in raw:
            key, value = raw.split(None, 1)
        else:
            continue
        values[key.strip()] = value.strip()

    try:
        sad_count = int(values.get("sad_count", "0"))
    except ValueError:
        sad_count = 0

    return EldState(
        card=int(match.group(1)),
        device=int(match.group(2)),
        connection_type=values.get("connection_type", ""),
        monitor_name=values.get("monitor_name", ""),
        sad_count=sad_count,
    )


def read_eld_states(cards: list[int]) -> list[EldState]:
    states: list[EldState] = []
    for card in cards:
        for name in sorted(glob.glob(f"{PROC}/card{card}/eld#*")):
            state = parse_eld(Path(name))
            if state:
                states.append(state)
    return states


def pactl_available() -> bool:
    return run(["sh", "-c", "command -v pactl"]).returncode == 0


def sink_names() -> set[str]:
    result = run(["pactl", "list", "short", "sinks"])
    if result.returncode != 0:
        return set()
    names: set[str] = set()
    for line in result.stdout.splitlines():
        fields = line.split("\t")
        if len(fields) >= 2:
            names.add(fields[1])
    return names


def current_default_sink() -> str | None:
    result = run(["pactl", "get-default-sink"])
    if result.returncode != 0:
        return None
    value = result.stdout.strip()
    return value or None


def first_non_ncz_sink() -> str | None:
    result = run(["pactl", "list", "short", "sinks"])
    if result.returncode != 0:
        return None
    for line in result.stdout.splitlines():
        fields = line.split("\t")
        if len(fields) >= 2 and not fields[1].startswith(OWN_PREFIXES):
            return fields[1]
    return None


def find_hw_sink(card: int, device: int) -> str | None:
    result = run(["pactl", "list", "sinks"])
    if result.returncode != 0:
        return None

    name: str | None = None
    props: dict[str, str] = {}

    def flush() -> str | None:
        if not name:
            return None
        card_value = props.get("alsa.card")
        device_value = props.get("alsa.device") or props.get("api.alsa.pcm.device")
        if card_value == str(card) and device_value == str(device):
            return name
        return None

    for raw in result.stdout.splitlines():
        line = raw.strip()
        if line.startswith("Sink #"):
            found = flush()
            if found:
                return found
            name = None
            props = {}
            continue
        if line.startswith("Name:"):
            name = line.split(":", 1)[1].strip()
            continue
        if "=" in line:
            key, value = line.split("=", 1)
            props[key.strip()] = value.strip().strip('"')

    return flush()


def load_sink(state: EldState, known_sinks: set[str], sink_name: str | None = None) -> bool:
    sink_name = sink_name or state.sink_name
    if sink_name in known_sinks:
        return True

    device = f"hw:{state.card},{state.device}"
    result = run(
        [
            "pactl",
            "load-module",
            "module-alsa-sink",
            f"sink_name={sink_name}",
            f"device={device}",
            "namereg_fail=false",
        ]
    )
    if result.returncode == 0:
        log(f"loaded {sink_name} for {device}")
        return True

    log(f"failed to load {sink_name} for {device}: {result.stderr.strip()}")
    return False


def ensure_sink(state: EldState, known_sinks: set[str]) -> str | None:
    if state.sink_name in known_sinks:
        return state.sink_name

    existing = find_hw_sink(state.card, state.device)
    if existing:
        return existing

    if load_sink(state, known_sinks):
        return state.sink_name
    return None


def set_default_sink(name: str) -> None:
    result = run(["pactl", "set-default-sink", name])
    if result.returncode != 0:
        log(f"failed to set default sink {name}: {result.stderr.strip()}")
        return

    inputs = run(["pactl", "list", "short", "sink-inputs"])
    if inputs.returncode != 0:
        return
    for line in inputs.stdout.splitlines():
        fields = line.split("\t")
        if fields:
            run(["pactl", "move-sink-input", fields[0], name])


def choose_connected(states: list[EldState], current: str | None) -> EldState | None:
    connected = sorted((state for state in states if state.connected), key=lambda s: s.device)
    if not connected:
        return None
    for state in connected:
        if current == state.sink_name:
            return state
    return connected[0]


def decide(current: str | None) -> tuple[str, int, int, str, str] | None:
    """Return (kind, card, device, sink_name, label) or None. Pure w.r.t. PipeWire."""
    states = read_eld_states(cix_cards())
    choice = choose_connected(states, current)
    if choice is not None:
        label = choice.monitor_name or choice.connection_type or f"pcm {choice.device}"
        return ("hdmi", choice.card, choice.device, choice.sink_name, label)
    for card in hda_cards():
        dev = analog_device(card)
        if dev is not None:
            return ("analog", card, dev, f"{ANALOG_PREFIX}_{card}_{dev}", "HDA analog out")
    return None


def unmute_analog(card: int) -> None:
    # Master is the HDA output stage; the Line Out jack rides on it. Never raise
    # a level that is already set, only clear a mute.
    run(["amixer", "-c", str(card), "-q", "sset", "Master", "unmute"])


def once(last_choice: str | None) -> str | None:
    current = current_default_sink()
    target_info = decide(current)
    if target_info is None:
        if current and current.startswith(OWN_PREFIXES):
            fallback = first_non_ncz_sink()
            if fallback:
                set_default_sink(fallback)
                log(f"no audio output available; restored fallback sink {fallback}")
                return fallback
        return last_choice

    kind, card, dev, sink, label = target_info
    known = sink_names()
    if kind == "analog":
        unmute_analog(card)
    if kind == "hdmi":
        target = ensure_sink(EldState(card, dev, "", label, 1), known)
    else:
        target = sink if sink in known else (find_hw_sink(card, dev) or (sink if load_sink(EldState(card, dev, "", label, 1), known, sink) else None))
    if target and current != target:
        set_default_sink(target)
        log(f"selected {target} ({label})")
        return target
    return last_choice


def main() -> int:
    if "--decide" in sys.argv:
        global PROC
        if "--proc-root" in sys.argv:
            idx = sys.argv.index("--proc-root") + 1
            if idx >= len(sys.argv):
                log("--proc-root needs a directory")
                return 2
            PROC = Path(sys.argv[idx])
            if not PROC.is_dir():
                log(f"--proc-root {PROC} is not a directory")
                return 2
        result = decide(None)
        print("none" if result is None else f"{result[0]} {result[3]} hw:{result[1]},{result[2]}")
        return 0
    if not pactl_available():
        log("pactl not installed; install pulseaudio-utils")
        return 1

    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if run(["pactl", "info"]).returncode == 0:
            break
        time.sleep(1)
    else:
        log("PulseAudio-compatible PipeWire server is not reachable")
        return 1

    last_choice: str | None = None
    while True:
        try:
            last_choice = once(last_choice)
        except Exception as exc:  # noqa: BLE001 - keep the user audio session alive.
            log(f"iteration failed: {exc}")
        time.sleep(float(os.environ.get("NCZ_SKY1_AUDIO_POLL_SECONDS", POLL_SECONDS)))


if __name__ == "__main__":
    raise SystemExit(main())
