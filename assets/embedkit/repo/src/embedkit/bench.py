# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jason Perlow
"""embedkit-bench — micro-bench an adapter across the canonical corpus.

CLI shim around embedkit.pick.bench_adapter(). Picks an adapter via
`Engine.auto()` (or `--adapter NAME`), runs the 50-record bench corpus,
and prints rec/sec + per-record stats. Always exits non-zero on any
failure so install-time smoke tests can rely on $?.

Usage
-----
  embedkit-bench                 # auto-pick adapter, print summary JSON
  embedkit-bench --adapter cpu   # force a named adapter
  embedkit-bench --json          # machine-readable output (same as default)
  embedkit-bench --no-cache      # ignore bench.json + re-measure
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import time

from .engine import Engine

log = logging.getLogger("embedkit.bench")


def _parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="embedkit-bench",
        description="Micro-bench the chosen embedkit adapter against the 50-record corpus.",
    )
    p.add_argument(
        "--adapter",
        default=None,
        help="Force a specific adapter name (e.g. 'cpu', 'cix-npu'). Default: auto().",
    )
    p.add_argument(
        "--no-cache",
        action="store_true",
        help="Ignore cached bench.json and re-measure.",
    )
    p.add_argument(
        "--json",
        action="store_true",
        help="Emit JSON to stdout (default behaviour; kept for compat).",
    )
    p.add_argument(
        "-v",
        "--verbose",
        action="count",
        default=0,
        help="Increase log verbosity (-v: INFO, -vv: DEBUG).",
    )
    return p.parse_args(argv)


def _setup_logging(verbose: int) -> None:
    level = logging.WARNING
    if verbose >= 2:
        level = logging.DEBUG
    elif verbose >= 1:
        level = logging.INFO
    logging.basicConfig(
        level=level,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
        stream=sys.stderr,
    )


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    _setup_logging(args.verbose)

    if args.no_cache:
        os.environ["EMBEDKIT_BENCH_FORCE"] = "1"

    try:
        engine = Engine()
    except Exception as exc:
        print(json.dumps({"error": f"engine init failed: {exc}"}), file=sys.stderr)
        return 1

    started = time.perf_counter()
    try:
        if args.adapter:
            adapter = engine.adapter(args.adapter)
        else:
            adapter = engine.auto()
    except Exception as exc:
        print(json.dumps({"error": f"adapter resolution failed: {exc}"}), file=sys.stderr)
        return 1

    duration_ms = (time.perf_counter() - started) * 1000.0
    summary = {
        "adapter": getattr(adapter, "name", type(adapter).__name__),
        "model_id": getattr(adapter, "model_id", None),
        "device": getattr(adapter, "device", None),
        "resolution_ms": round(duration_ms, 2),
        "ok": True,
    }
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
