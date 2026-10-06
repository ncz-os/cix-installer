#!/usr/bin/env python3
"""Auto-route CIX Sky1 audio: HDMI/DP with a live ELD, else the HDA analog out.

Policy (board agnostic; O6N has only the 3 DP links, MS-R1 also has the
cix-ipbloq-hda ALC269 analog/digital card):
  1. a cix,sky1 DP/HDMI PCM whose ELD reports audio (sad_count > 0) wins, but
     only if the PCM actually accepts hw_params: it is opened once with aplay
     (48 kHz S16 stereo, 50 ms of silence) before a sink is made for it. A
     PCM that refuses (EINVAL: on 7.3-rc6 the MS-R1 I2S MCLK reads 0 Hz) or a
     sink that vanishes right after selection is parked with an exponential
     back-off (30 s .. 10 min) and logged once, never reloaded every poll;
  2. else the analog PCM of a cix-ipbloq-hda card. WirePlumber marks its
     profiles unavailable while the line-out jack reads unplugged, so it would
     create no sink at all; we deliberately create one anyway (powered speakers
     without jack sensing, or a plug inserted later, then just work). The
     price is that an unplugged line-out is a silent default, not "no sink";
  (several connected monitors: the lowest PCM index wins, kept while current)
  3. else nothing: leave PipeWire's own default alone.
`--decide [--proc-root DIR]` prints the decision without touching PipeWire
(it does run the aplay hw_params probe for a candidate DP/HDMI PCM).

This is deliberately a user-session helper instead of a PipeWire static
drop-in. If PipeWire Pulse rejects a module load, this process logs and keeps
running; it does not participate in pipewire.service startup.
"""

from __future__ import annotations

import glob
import json
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
SILENT_SINK = "ncz_sky1_silent"
OWN_PREFIXES = (SINK_PREFIX, ANALOG_PREFIX, SILENT_SINK)
BACKOFF_START = 30.0
BACKOFF_MAX = 600.0
PROBE_TIMEOUT = 5.0


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
        # pactl/pw-dump can print client-supplied property bytes that are not UTF-8 (seen live
        # on O6N with a Chromium stream: every iteration died with UnicodeDecodeError)
        encoding="utf-8",
        errors="replace",
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
        for m in (
            re.search(r"pcm(\d+)p$", str(p))
            for p in glob.glob(f"{PROC}/card{card}/pcm*p")
        )
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


def first_non_ncz_sink(avoid: frozenset[str] | set[str] = frozenset()) -> str | None:
    result = run(["pactl", "list", "short", "sinks"])
    if result.returncode != 0:
        return None
    for line in result.stdout.splitlines():
        fields = line.split("\t")
        if (
            len(fields) >= 2
            and not fields[1].startswith(OWN_PREFIXES)
            and fields[1] not in avoid
        ):
            return fields[1]
    return None


def errored_sinks() -> set[str]:
    """node.name of every PipeWire node currently in the "error" state (e.g. Start error EINVAL).

    A sink in that state stays listed by pactl, but a stream routed to it never runs: pw-play
    hangs and Chromium's media clock stalls on the audio track, so video "freezes" too.
    """
    try:
        result = run(["pw-dump"])
    except (
        OSError
    ):  # pipewire-bin without pw-dump: no error-state detection, keep going
        return set()
    if result.returncode != 0 or not result.stdout.strip():
        return set()
    try:
        objects = json.loads(result.stdout)
    except ValueError:
        return set()
    names: set[str] = set()
    for obj in objects if isinstance(objects, list) else []:
        info = obj.get("info") or {}
        if (
            obj.get("type") == "PipeWire:Interface:Node"
            and info.get("state") == "error"
        ):
            name = (info.get("props") or {}).get("node.name")
            if name:
                names.add(name)
    return names


def ensure_silent_sink(known_sinks: set[str]) -> bool:
    """A null sink to fall back to when every real output is broken, so apps keep their clocks."""
    if SILENT_SINK in known_sinks:
        return True
    result = run(
        [
            "pactl",
            "load-module",
            "module-null-sink",
            f"sink_name={SILENT_SINK}",
            "sink_properties=device.description=No-working-audio-output",
        ]
    )
    if result.returncode != 0:
        log(f"failed to load {SILENT_SINK}: {result.stderr.strip()}")
        return False
    log(f"loaded {SILENT_SINK}: no working audio output")
    return True


def find_hw_sink(card: int, device: int, exclude_own: bool = False) -> str | None:
    """Name of a sink already bound to hw:card,device (optionally ignoring this daemon's own sinks)."""
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
            if exclude_own and name.startswith(OWN_PREFIXES):
                return None
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


def load_sink(
    state: EldState, known_sinks: set[str], sink_name: str | None = None
) -> bool:
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


def unload_own_sink(name: str) -> None:
    """Unload the module-alsa-sink/module-null-sink this daemon loaded for `name` (no-op if absent)."""
    result = run(["pactl", "list", "short", "modules"])
    if result.returncode != 0:
        return
    for line in result.stdout.splitlines():
        fields = line.split("\t")
        if (
            len(fields) >= 3
            and fields[1] in ("module-alsa-sink", "module-null-sink")
            and f"sink_name={name}" in fields[2].split()
        ):
            run(["pactl", "unload-module", fields[0]])
            log(f"unloaded {name}")


def set_default_sink(name: str) -> bool:
    result = run(["pactl", "set-default-sink", name])
    if result.returncode != 0:
        log(f"failed to set default sink {name}: {result.stderr.strip()}")
        return False

    inputs = run(["pactl", "list", "short", "sink-inputs"])
    if inputs.returncode != 0:
        return
    for line in inputs.stdout.splitlines():
        fields = line.split("\t")
        if fields:
            run(["pactl", "move-sink-input", fields[0], name])
    return True


def choose_connected(states: list[EldState], current: str | None) -> EldState | None:
    connected = sorted(
        (state for state in states if state.connected), key=lambda s: s.device
    )
    if not connected:
        return None
    for state in connected:
        if current == state.sink_name:
            return state
    return connected[0]


def probe_pcm(card: int, device: int) -> tuple[bool, str]:
    """Open hw:card,device with plain hw_params (48 kHz S16 stereo) and play 50 ms of silence.

    Returns (usable, reason). A busy PCM counts as usable: someone (normally our
    own running sink) already opened it successfully. A missing aplay skips the
    probe rather than blocking every DP/HDMI sink.
    """
    argv = [
        "aplay",
        "-q",
        "-D",
        f"hw:{card},{device}",
        "-t",
        "raw",
        "-f",
        "S16_LE",
        "-c",
        "2",
        "-r",
        "48000",
        "-s",
        "2400",
        "/dev/zero",
    ]
    try:
        result = subprocess.run(
            argv, text=True, capture_output=True, timeout=PROBE_TIMEOUT, check=False
        )
    except FileNotFoundError:
        return True, "aplay not installed; probe skipped"
    except subprocess.TimeoutExpired:
        return False, f"aplay hw:{card},{device} timed out"
    # first line only: aplay follows a hw_params failure with a full parameter dump
    err = next((ln.strip() for ln in result.stderr.splitlines() if ln.strip()), "")
    if result.returncode == 0:
        return True, "ok"
    if "busy" in err.lower():
        return True, "busy (already open)"
    return False, err[:160] or f"aplay rc={result.returncode}"


class Backoff:
    """Per-PCM failure memory so a broken DP/HDMI PCM is retried rarely and logged once."""

    def __init__(self, clock=time.monotonic) -> None:
        self.clock = clock
        # key -> (retry_at, delay, monitor) for PCMs that failed; `good` holds PCMs this
        # process has itself seen accept hw_params (a pre-existing sink proves nothing: a
        # module-alsa-sink loads fine and only fails when a stream starts).
        self.bad: dict[tuple[int, int], tuple[float, float, str]] = {}
        self.good: set[tuple[int, int]] = set()

    def parked(self, key: tuple[int, int], monitor: str) -> bool:
        entry = self.bad.get(key)
        if entry is None:
            return False
        retry_at, _delay, seen_monitor = entry
        if monitor and seen_monitor and monitor != seen_monitor:
            # a different display was plugged in: give it a fresh chance
            del self.bad[key]
            return False
        return self.clock() < retry_at

    def fail(self, key: tuple[int, int], monitor: str, reason: str) -> None:
        self.good.discard(key)
        prev = self.bad.get(key)
        delay = BACKOFF_START if prev is None else min(prev[1] * 2, BACKOFF_MAX)
        self.bad[key] = (self.clock() + delay, delay, monitor)
        log(
            f"hw:{key[0]},{key[1]} ({monitor or 'display'}) is not usable: {reason}; "
            f"using the next output, re-checking in {int(delay)} s"
        )

    def ok(self, key: tuple[int, int]) -> None:
        self.good.add(key)
        if self.bad.pop(key, None) is not None:
            log(f"hw:{key[0]},{key[1]} accepts hw_params again")


def probing_usable(backoff: Backoff | None = None, skip=None):
    """Build the usable(state) predicate decide() uses: back-off first, then the aplay probe."""

    def usable(state: EldState) -> bool:
        key = (state.card, state.device)
        if skip is not None and skip(state):
            return True
        if backoff is not None and backoff.parked(key, state.monitor_name):
            return False
        good, reason = probe_pcm(state.card, state.device)
        if backoff is not None:
            if good:
                backoff.ok(key)
            else:
                backoff.fail(key, state.monitor_name, reason)
        return good

    return usable


def decide(current: str | None, usable=None) -> tuple[str, int, int, str, str] | None:
    """Return (kind, card, device, sink_name, label) or None. Pure w.r.t. PipeWire.

    usable(state) filters DP/HDMI candidates (hw_params probe + back-off); None accepts all.
    """
    states = [s for s in read_eld_states(cix_cards()) if s.connected]
    if usable is not None:
        states = [s for s in states if usable(s)]
    choice = choose_connected(states, current)
    if choice is not None:
        label = choice.monitor_name or choice.connection_type or f"pcm {choice.device}"
        return ("hdmi", choice.card, choice.device, choice.sink_name, label)
    for card in hda_cards():
        dev = analog_device(card)
        if dev is not None:
            return (
                "analog",
                card,
                dev,
                f"{ANALOG_PREFIX}_{card}_{dev}",
                "HDA analog out",
            )
    return None


def unmute_analog(card: int) -> None:
    # Master is the HDA output stage; the Line Out jack rides on it. Never raise
    # a level that is already set, only clear a mute.
    run(["amixer", "-c", str(card), "-q", "sset", "Master", "unmute"])


class Switcher:
    """One daemon instance: remembers what it selected and which DP/HDMI PCMs are parked."""

    def __init__(self) -> None:
        self.backoff = Backoff()
        self.last_choice: str | None = None
        self.last_hdmi: tuple[int, int, str] | None = (
            None  # (card, device, monitor) of the sink we selected
        )

    def once(self) -> str | None:
        current = current_default_sink()
        known = sink_names()
        errored = errored_sinks()

        # A DP/HDMI sink we selected that is gone again failed to start (PipeWire Pulse drops a
        # module-alsa-sink whose node errors, e.g. set_hw_params EINVAL): park it, do not reload.
        if self.last_hdmi is not None:
            card, dev, monitor = self.last_hdmi
            name = f"{SINK_PREFIX}_{card}_{dev}"
            if self.last_choice == name and (name not in known or name in errored):
                why = "disappeared" if name not in known else "is in the error state"
                self.backoff.fail(
                    (card, dev),
                    monitor,
                    f"its sink {why} after selection (start error)",
                )
                self.last_hdmi = None
                self.last_choice = None

        def already_good(state: EldState) -> bool:
            # our sink is the default and THIS process probed its PCM successfully: do not
            # re-open the PCM under it every poll
            return (
                state.sink_name in known
                and current == state.sink_name
                and (state.card, state.device) in self.backoff.good
            )

        target_info = decide(current, probing_usable(self.backoff, skip=already_good))

        # Our own sink on a parked PCM (e.g. left by an earlier instance, or one that just failed)
        # would keep attracting streams that then fail with "Start error": unload it.
        for card, dev in list(self.backoff.bad):
            stale = f"{SINK_PREFIX}_{card}_{dev}"
            if stale in known:
                unload_own_sink(stale)
                known.discard(stale)
        if target_info is None:
            if current and (current.startswith(OWN_PREFIXES) or current in errored):
                fallback = first_non_ncz_sink(avoid=errored)
                if fallback:
                    if set_default_sink(fallback):
                        log(
                            f"no audio output available; restored fallback sink {fallback}"
                        )
                        self.last_choice = fallback
                elif (
                    current != SILENT_SINK
                    and ensure_silent_sink(known)
                    and set_default_sink(SILENT_SINK)
                ):
                    # every real sink is broken: a silent default keeps players running instead of
                    # hanging on a sink that never starts
                    self.last_choice = SILENT_SINK
            return self.last_choice

        kind, card, dev, sink, label = target_info
        if kind == "hdmi":
            target = ensure_sink(EldState(card, dev, "", label, 1), known)
        else:
            # Prefer a sink WirePlumber made for the same PCM (its ACP profile became available, e.g.
            # a jack was plugged in): two sinks on one hw PCM fight over it, so drop ours.
            native = find_hw_sink(card, dev, exclude_own=True)
            if native:
                target = native
            elif sink in known or load_sink(
                EldState(card, dev, "", label, 1), known, sink
            ):
                target = sink
            else:
                target = None
        if target and current != target:
            if kind == "analog":
                # clear the codec mute once, when the analog sink BECOMES the default; never on later polls, so a mute
                # the user applies afterwards is respected (zoder review of d0e6066, finding 1)
                unmute_analog(card)
            if set_default_sink(target):
                log(f"selected {target} ({label})")
                self.last_choice = target
                self.last_hdmi = (card, dev, label) if kind == "hdmi" else None
        if kind == "analog" and target and target != sink and sink in known:
            unload_own_sink(sink)
        if target and self.last_choice == target and SILENT_SINK in known:
            unload_own_sink(SILENT_SINK)
        return self.last_choice


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
        result = decide(None, probing_usable())
        print(
            "none"
            if result is None
            else f"{result[0]} {result[3]} hw:{result[1]},{result[2]}"
        )
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

    switcher = Switcher()
    # NCZ_SKY1_AUDIO_ITERATIONS bounds the loop for the stubbed-pactl tests; unset means forever.
    remaining = int(os.environ.get("NCZ_SKY1_AUDIO_ITERATIONS", "0") or 0)
    while True:
        try:
            switcher.once()
        except Exception as exc:  # noqa: BLE001 - keep the user audio session alive.
            log(f"iteration failed: {exc}")
        if remaining:
            remaining -= 1
            if remaining == 0:
                return 0
        time.sleep(float(os.environ.get("NCZ_SKY1_AUDIO_POLL_SECONDS", POLL_SECONDS)))


if __name__ == "__main__":
    raise SystemExit(main())
