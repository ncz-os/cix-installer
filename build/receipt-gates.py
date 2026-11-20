#!/usr/bin/env python3
"""receipt-gates.py -- summarize a build run's gate result files into gates.json.

WHY. The image receipt (run-metadata.json) records the kvm/provenance/secret-scan
results, but the archive-side gate summary must also evidence the two rules that
the brief names explicitly: one_kernel and ui. Both are already measured during
the build -- one_kernel inside the provenance gate (provenance.result carries
`one_kernel=PASS`) and ui inside the KVM gate (kvm-gate.result carries `ui=PASS`,
or `ui=server` for a medium server image, which has no desktop UI to check) --
they were just never copied into the summary written next to the image.

Usage: receipt-gates.py RUN_DIR [--variant desktop|server] [--mode full|...]
Writes JSON on stdout. Exit 0 whenever the summary could be produced; the
verdict is `all_required_passed`, not the exit code, so a caller can always
attach the file and let the gate itself fail the build.
"""
import json
import os
import sys

RESULT_FILES = {
    "kvm": "kvm-gate.result",
    "provenance": "provenance.result",
    "secret_scan": "secret-scan.result",
    "provenance_inputs": "provenance-inputs.result",
    "layers_preflight": "layers-preflight.result",
    "layers_postcheck": "layers-postcheck.result",
}
REQUIRED = ("kvm", "one_kernel", "provenance", "secret_scan", "ui")
# ui values that mean "this variant has no desktop UI check to run"
UI_NOT_APPLICABLE = ("server", "n/a", "na", "skip")


def read(run_dir, name):
    try:
        with open(os.path.join(run_dir, name), encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def field(text, key):
    for line in text.splitlines():
        k, sep, v = line.partition("=")
        if sep and k.strip() == key:
            return v.strip()
    return ""


def verdict(text):
    if not text:
        return "not-run"
    return "PASS" if field(text, "result") == "PASS" else "FAIL"


def summarize(run_dir, variant):
    gates = {name: verdict(read(run_dir, path)) for name, path in RESULT_FILES.items()}

    prov = read(run_dir, RESULT_FILES["provenance"])
    one = field(prov, "one_kernel").upper()
    gates["one_kernel"] = "PASS" if one == "PASS" else ("FAIL" if one else "not-run")

    kvm = read(run_dir, RESULT_FILES["kvm"])
    ui = field(kvm, "ui")
    if ui.upper() == "PASS":
        gates["ui"] = "PASS"
    elif ui.upper() == "FAIL":
        gates["ui"] = "FAIL"
    elif ui.lower() in UI_NOT_APPLICABLE:
        gates["ui"] = "N/A"
    else:
        gates["ui"] = "not-run"

    hard = [gates["kvm"], gates["provenance"], gates["one_kernel"], gates["secret_scan"]]
    ui_ok = gates["ui"] == "PASS" or (variant == "server" and gates["ui"] == "N/A")
    return {
        "schema": "ncz-image-gates/v1",
        "variant": variant,
        "gates": gates,
        "required": list(REQUIRED),
        "all_required_passed": all(v == "PASS" for v in hard) and ui_ok,
        "note": "Derived from the run's *.result files; one_kernel comes from "
                "provenance.result and ui from kvm-gate.result (ui=server means a "
                "medium server image has no desktop UI check and is recorded N/A).",
    }


def main(argv):
    run_dir = argv[1] if len(argv) > 1 else "."
    variant = "desktop"
    i = 2
    while i < len(argv):
        if argv[i] == "--variant" and i + 1 < len(argv):
            variant = argv[i + 1]
            i += 2
        elif argv[i] == "--mode" and i + 1 < len(argv):
            i += 2
        else:
            i += 1
    if variant not in ("desktop", "server"):
        print(f"receipt-gates.py: unknown variant {variant!r}", file=sys.stderr)
        return 2
    json.dump(summarize(run_dir, variant), sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
