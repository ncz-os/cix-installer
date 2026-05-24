# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jason Perlow
"""embedkit-doctor — host/runtime diagnostics for embedkit.

Reports which adapters are available, which model files are present at
expected paths, NPU device-node presence (/dev/aipu on Cix Sky1, etc.),
and Python/runtime versions. Always exits non-zero when any required
adapter, model file, or runtime check fails so install-time smoke tests
can rely on $?.

Usage
-----
  embedkit-doctor                 # human-readable text summary
  embedkit-doctor --json          # machine-readable structured output
  embedkit-doctor --strict        # exit non-zero on any warning (default: errors only)
"""
from __future__ import annotations

import argparse
import json
import logging
import platform
import sys
from pathlib import Path

log = logging.getLogger("embedkit.doctor")


def _python_runtime() -> dict[str, str]:
    return {
        "python_version": platform.python_version(),
        "implementation": platform.python_implementation(),
        "platform": platform.platform(),
        "machine": platform.machine(),
    }


def _adapter_probes() -> list[dict[str, object]]:
    """Probe each adapter import path; report present-or-missing.

    Doesn't INSTANTIATE the adapter (cheap probe). Instantiation +
    capability check live in `embedkit-bench`.
    """
    probes: list[dict[str, object]] = []
    candidates = [
        ("cpu", "embedkit.adapters.cpu"),
        ("cix_npu", "embedkit.adapters.cix_npu"),
        ("onnx", "embedkit.adapters.onnx"),
    ]
    import importlib

    for name, module_path in candidates:
        entry: dict[str, object] = {"name": name, "module": module_path}
        try:
            importlib.import_module(module_path)
            entry["status"] = "ok"
        except ImportError as exc:
            entry["status"] = "missing"
            entry["error"] = str(exc)
        except Exception as exc:  # noqa: BLE001
            entry["status"] = "error"
            entry["error"] = f"{type(exc).__name__}: {exc}"
        probes.append(entry)
    return probes


def _device_nodes() -> list[dict[str, object]]:
    """Check NPU / accelerator device-node presence (Linux-only paths;
    the entries silently report `present=False` on other OSes)."""
    nodes = [
        ("aipu", "/dev/aipu"),
        ("accel0", "/dev/accel/accel0"),
        ("dxg", "/dev/dxg"),
    ]
    out: list[dict[str, object]] = []
    for name, path in nodes:
        p = Path(path)
        out.append({
            "name": name,
            "path": path,
            "present": p.exists(),
        })
    return out


def _model_files() -> list[dict[str, object]]:
    """Check well-known model file paths (cix vs gguf)."""
    candidates = [
        ("bge-small-cix", "/opt/embedkit/models/bge-small-zh-v1.5_256.cix"),
        ("bge-small-gguf", "/opt/embedkit/models/bge-small-zh-v1.5-q8_0.gguf"),
    ]
    out: list[dict[str, object]] = []
    for name, path in candidates:
        p = Path(path)
        size = p.stat().st_size if p.exists() else None
        out.append({
            "name": name,
            "path": path,
            "present": p.exists(),
            "size_bytes": size,
        })
    return out


def _build_report() -> dict[str, object]:
    return {
        "runtime": _python_runtime(),
        "adapters": _adapter_probes(),
        "devices": _device_nodes(),
        "models": _model_files(),
    }


def _decide_exit(report: dict[str, object], strict: bool) -> int:
    """Exit non-zero when any required check fails. Hard requirements:
       * at least one adapter import successful
       * Python >= 3.10
    Warnings (no required device, no required model file) only fail
    when --strict.
    """
    adapters = report.get("adapters", [])
    if not any(a.get("status") == "ok" for a in adapters):  # type: ignore[arg-type]
        return 1
    py = report.get("runtime", {}).get("python_version", "0")  # type: ignore[union-attr]
    if isinstance(py, str):
        parts = py.split(".")
        try:
            major, minor = int(parts[0]), int(parts[1])
            if (major, minor) < (3, 10):
                return 1
        except (ValueError, IndexError):
            return 1
    if strict:
        devices = report.get("devices", [])
        models = report.get("models", [])
        if not any(d.get("present") for d in devices):  # type: ignore[arg-type]
            return 1
        if not any(m.get("present") for m in models):  # type: ignore[arg-type]
            return 1
    return 0


def _emit_text(report: dict[str, object]) -> None:
    rt = report["runtime"]
    print(f"python {rt['python_version']} ({rt['implementation']}) on {rt['platform']}")
    print()
    print("adapters:")
    for a in report["adapters"]:  # type: ignore[union-attr]
        marker = "✓" if a["status"] == "ok" else "✗"
        line = f"  {marker} {a['name']:12s} {a['status']:8s} {a['module']}"
        if a.get("error"):
            line += f"  ({a['error']})"
        print(line)
    print()
    print("devices:")
    for d in report["devices"]:  # type: ignore[union-attr]
        marker = "✓" if d["present"] else "·"
        print(f"  {marker} {d['name']:12s} {d['path']}")
    print()
    print("models:")
    for m in report["models"]:  # type: ignore[union-attr]
        marker = "✓" if m["present"] else "·"
        size = f" ({m['size_bytes']} bytes)" if m.get("size_bytes") else ""
        print(f"  {marker} {m['name']:14s} {m['path']}{size}")


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        prog="embedkit-doctor",
        description="Diagnose embedkit adapters, devices, models, and runtime.",
    )
    p.add_argument("--json", action="store_true", help="Emit JSON instead of human text")
    p.add_argument(
        "--strict",
        action="store_true",
        help="Exit non-zero on warnings (missing devices / models), not just hard errors",
    )
    args = p.parse_args(argv)

    report = _build_report()
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True, default=str))
    else:
        _emit_text(report)
    return _decide_exit(report, strict=args.strict)


if __name__ == "__main__":
    sys.exit(main())
