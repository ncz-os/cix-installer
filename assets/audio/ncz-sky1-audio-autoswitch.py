#!/usr/bin/env python3
"""Auto-route CIX Sky1 HDMI/DP audio to the connected ELD output.

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
    cards = Path("/proc/asound/cards")
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
        for name in sorted(glob.glob(f"/proc/asound/card{card}/eld#*")):
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
        if len(fields) >= 2 and not fields[1].startswith(SINK_PREFIX):
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


def load_sink(state: EldState, known_sinks: set[str]) -> bool:
    if state.sink_name in known_sinks:
        return True

    device = f"hw:{state.card},{state.device}"
    result = run(
        [
            "pactl",
            "load-module",
            "module-alsa-sink",
            f"sink_name={state.sink_name}",
            f"device={device}",
            "namereg_fail=false",
        ]
    )
    if result.returncode == 0:
        log(f"loaded {state.sink_name} for {device}")
        return True

    log(f"failed to load {state.sink_name} for {device}: {result.stderr.strip()}")
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


def once(last_choice: str | None) -> str | None:
    cards = cix_cards()
    if not cards:
        return last_choice

    states = read_eld_states(cards)
    if not states:
        return last_choice

    current = current_default_sink()
    choice = choose_connected(states, current)
    if choice is None:
        if current and current.startswith(SINK_PREFIX):
            fallback = first_non_ncz_sink()
            if fallback:
                set_default_sink(fallback)
                log(f"no connected display ELD; restored fallback sink {fallback}")
                return fallback
        return last_choice

    known = sink_names()
    target = ensure_sink(choice, known)
    if target and current != target:
        set_default_sink(target)
        label = choice.monitor_name or choice.connection_type or f"pcm {choice.device}"
        log(f"selected {target} ({label})")
        return target
    return last_choice


def main() -> int:
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
