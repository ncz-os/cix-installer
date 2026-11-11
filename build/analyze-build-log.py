#!/usr/bin/env python3
"""Classify build-log failures chunk-by-chunk with an OpenAI-style chat model.

Given a build log (a build-image.sh .out file, or a per-stage logs/ directory),
split it into chunks, ask the model for strict JSON per chunk
{failure_class: C1..C9|ok, first_error_line, cause, evidence: [line numbers]},
then merge the chunk answers into one report.

Build logs contain every line twice (the tee bug: stage functions pipe through
``tee -a`` and run_stage() pipes the function through ``tee -a`` again — see
BUILD-STABILITY-stab1.md section 1), so doubled consecutive lines are removed
before chunking while the chunk text keeps the ORIGINAL file line numbers,
meaning model-cited evidence line numbers always refer to original numbering.

Usage:
    analyze-build-log.py <log-or-dir> [--model-url URL] [--model NAME]
                         [--chunk-lines N] [--timeout SEC] [--out report.json]
"""

import argparse
import json
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

DEFAULT_MODEL_URL = "http://127.0.0.1:8095/v1/chat/completions"
DEFAULT_MODEL = "local"
DEFAULT_CHUNK_LINES = 200

CLASSES = ("C1", "C2", "C3", "C4", "C5", "C6", "C7", "C8", "C9", "ok")

TAXONOMY = (
    "C1 pin/ledger drift on re-pin (symptoms: FAIL [sid-exceptions] rows such as "
    "GRADUATED udebs, 'ledger row pinned to snapshot ... != current pin', "
    "'an input has an unreviewed origin' reported by the provenance-inputs stage); "
    "C2 per-host input drift; "
    "C3 late provenance (stage 80 provenance-gate finds input defects, e.g. udebs "
    "present in the pinned snapshot index but missing from sid-exceptions manifests); "
    "C4 tests with hard-coded pins; "
    "C5 stale intermediate artifacts; "
    "C6 env/permission debris that blocks the build (ownership or permission errors "
    "that need chown/chmod to clear - never benign warnings); "
    "C7 operator-procedure mistakes; C8 network/mirror flakiness; C9 resource limits; "
    "ok no failure observed in this chunk"
)

SYSTEM_PROMPT = (
    "You are a build-log failure classifier. You reply with ONLY a JSON object, "
    "no prose. Schema: "
    '{"failure_class": "C1".."C9" or "ok", "first_error_line": integer or null, '
    '"cause": one sentence, "evidence": [integers]}. '
    "Line numbers in the text are ORIGINAL file line numbers; cite those. "
    "Warning-only lines (apt 'W:' notices such as unsandboxed downloads) are "
    "never failures on their own: classify the chunk ok unless a real ERROR or "
    "abort is present. "
    "Failure taxonomy: " + TAXONOMY
)


class MalformedResponse(Exception):
    """Model reply was not strict schema JSON after the one allowed retry."""


def load_lines(path):
    """Return [(original_line_number, text)] with 1-based original numbering."""
    items = []
    for no, raw in enumerate(path.read_text(errors="replace").splitlines(), 1):
        items.append((no, raw))
    return items


def dedup_doubled(items):
    """Collapse only the tee-bug pairs of consecutive identical lines.

    The tee bug duplicates every line exactly once, so a run of 2k identical
    raw lines is k logical lines (a run of 2k+1 leaves one unpaired twin):
    consume at most TWO equal items per step, keeping the first of each pair.
    Genuine repetitions (runs longer than 2) therefore survive, and the kept
    item always carries the ORIGINAL file line number of its first occurrence.
    """
    out = []
    i = 0
    while i < len(items):
        out.append(items[i])
        i += 2 if i + 1 < len(items) and items[i + 1][1] == items[i][1] else 1
    return out


def chunked(items, n):
    """Split items into consecutive chunks of at most n lines."""
    return [items[i : i + n] for i in range(0, len(items), n)] or [[]]


def render(items):
    """Render chunk text as 'original_number|text' so evidence cites originals."""
    return "\n".join(f"{no}|{text}" for no, text in items)


def validate_answer(obj):
    """Strict-JSON schema check; raises MalformedResponse when invalid."""
    if not isinstance(obj, dict):
        raise MalformedResponse("answer is not a JSON object")
    fc = obj.get("failure_class")
    if fc not in CLASSES:
        raise MalformedResponse(f"failure_class {fc!r} not in {CLASSES}")
    fil = obj.get("first_error_line")
    if fil is not None and (not isinstance(fil, int) or isinstance(fil, bool)):
        raise MalformedResponse(f"first_error_line {fil!r} is not an integer or null")
    cause = obj.get("cause")
    if not isinstance(cause, str):
        raise MalformedResponse(f"cause {cause!r} is not a string")
    ev = obj.get("evidence")
    if not isinstance(ev, list) or any(
        not isinstance(x, int) or isinstance(x, bool) for x in ev
    ):
        raise MalformedResponse(f"evidence {ev!r} is not a list of integers")
    return {
        "failure_class": fc,
        "first_error_line": fil,
        "cause": cause,
        "evidence": ev,
    }


def post_once(url, model, chunk_text, timeout=120.0):
    """One logical request. Falls back to no response_format on a 400 mentioning it."""
    body = {
        "model": model,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {
                "role": "user",
                "content": "Classify this build-log chunk:\n" + chunk_text,
            },
        ],
        "response_format": {"type": "json_object"},
    }

    def send(payload):
        req = urllib.request.Request(
            url,
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode(errors="replace")
        try:
            return json.loads(raw)
        except json.JSONDecodeError as exc:
            raise MalformedResponse(f"reply envelope is not JSON: {exc}") from exc

    try:
        data = send(body)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")
        if exc.code == 400 and "response_format" in detail:
            body.pop("response_format", None)
            data = send(body)
        else:
            raise MalformedResponse(f"HTTP {exc.code}: {detail[:200]}") from exc

    try:
        content = data["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError) as exc:
        raise MalformedResponse(f"unexpected reply shape: {exc}") from exc
    try:
        answer = json.loads(content)
    except json.JSONDecodeError as exc:
        raise MalformedResponse(f"content is not JSON: {exc}") from exc
    return validate_answer(answer)


def call_model(url, model, chunk_text, timeout=120.0):
    """Ask the model; exactly ONE retry on malformed JSON, then raise."""
    try:
        return post_once(url, model, chunk_text, timeout)
    except MalformedResponse:
        pass
    return post_once(url, model, chunk_text, timeout)


def analyze_file(path, model_url, model, chunk_lines, timeout=120.0):
    """Return (chunks, errors, deduped items) for one log file."""
    items = dedup_doubled(load_lines(path))
    chunks, errors = [], []
    for index, part in enumerate(chunked(items, chunk_lines)):
        try:
            answer = call_model(model_url, model, render(part), timeout)
        except MalformedResponse as exc:
            errors.append({"file": path.name, "index": index, "error": str(exc)})
            continue
        except TimeoutError as exc:
            # Explicit for readability (TimeoutError is an OSError, so the
            # transport clause below also covers it): a request timeout is a
            # recorded chunk error and is NEVER retried.
            errors.append(
                {"file": path.name, "index": index, "error": f"transport: {exc}"}
            )
            continue
        except (urllib.error.URLError, OSError, ValueError) as exc:
            errors.append(
                {"file": path.name, "index": index, "error": f"transport: {exc}"}
            )
            continue
        chunks.append(
            {
                "file": path.name,
                "index": index,
                "original_lines": [part[0][0], part[-1][0]] if part else [],
                **answer,
            }
        )
    return chunks, errors, items


ABORT_RE = re.compile(r"build aborted|FAILED rc=")


def merge(chunks, errors, lines=None):
    """Merge chunk answers with terminal-failure semantics.

    The chunk that CONTAINS the build-abort marker decides the class and the
    first error line (builds die at their abort); when no marker is found the
    LAST non-ok chunk wins (end-of-log is where builds die). All causes and
    evidence are preserved. Justification: the A1 accuracy measurement
    (2026-11-11) showed first-non-ok-wins let a benign apt W: warning in an
    early chunk hijack the merged verdict away from the terminal failure.
    """
    causes = []
    evidence = []
    non_ok = [rec for rec in chunks if rec["failure_class"] != "ok"]
    for rec in non_ok:
        causes.append(rec["cause"])
    for rec in chunks:
        for line in rec["evidence"]:
            if line not in evidence:
                evidence.append(line)
    abort_no = None
    for no, text in lines or []:
        if ABORT_RE.search(text):
            abort_no = no
    winner = None
    if abort_no is not None:
        for rec in non_ok:
            lo, hi = rec.get("original_lines") or (None, None)
            if lo is not None and lo <= abort_no <= hi:
                winner = rec
                break
    if winner is None and non_ok:
        winner = non_ok[-1]
    if winner is not None:
        failure_class = winner["failure_class"]
        first_error_line = winner["first_error_line"]
        if first_error_line is None:
            cands = [
                rec["first_error_line"]
                for rec in non_ok
                if rec["first_error_line"] is not None
            ]
            first_error_line = min(cands) if cands else None
    else:
        failure_class = "ok"
        first_error_line = None
    if errors and failure_class == "ok":
        failure_class = "unknown"
    return {
        "failure_class": failure_class,
        "first_error_line": first_error_line,
        "causes": causes,
        "evidence": evidence,
    }


def gather_inputs(root):
    """A file is one input; a directory yields its files in sorted order."""
    if root.is_file():
        return [root]
    return sorted(p for p in root.iterdir() if p.is_file())


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Classify build-log failures via a chat model."
    )
    parser.add_argument("log_or_dir", type=Path)
    parser.add_argument("--model-url", default=DEFAULT_MODEL_URL)
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--chunk-lines", type=int, default=DEFAULT_CHUNK_LINES)
    parser.add_argument(
        "--timeout",
        type=float,
        default=120.0,
        help="per-request timeout in seconds (CPU-served models need more)",
    )
    parser.add_argument("--out", type=Path, default=None)
    args = parser.parse_args(argv)

    if args.chunk_lines < 1:
        parser.error("--chunk-lines must be >= 1")

    chunks, errors, all_items = [], [], []
    for path in gather_inputs(args.log_or_dir):
        file_chunks, file_errors, file_items = analyze_file(
            path, args.model_url, args.model, args.chunk_lines, args.timeout
        )
        chunks.extend(file_chunks)
        errors.extend(file_errors)
        all_items.extend(file_items)

    report = {
        "source": str(args.log_or_dir),
        "model_url": args.model_url,
        "model": args.model,
        "chunk_lines": args.chunk_lines,
        "chunks": chunks,
        "chunk_errors": errors,
        **merge(chunks, errors, all_items),
    }
    text = json.dumps(report, indent=2) + "\n"
    if args.out:
        args.out.write_text(text)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
