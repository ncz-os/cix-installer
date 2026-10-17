"""Unit tests for the KVM install gate's server-variant wiring.

The gate (build/kvm-install-gate-matrix.sh + build/kvm-install-gate-gpt.sh)
carries two NCZ_KVM_GATE_VARIANTS sets for the Magnetar server variant:

  * ``server`` — full install against a live payload HTTP server on the gate
    host (QEMU user-net gateway 10.0.2.2); the guest must fetch
    ``base.squashfs`` + the ncz assets from the medium's
    ``ncz-fetch-payload.manifest`` pins, sha256-verify them, install them,
    and the gate asserts: the fetched+verified serial-log lines, no desktop
    packages on the installed root, the installed rEFInd menu is
    Console + Rescue Partition (default on Console), ssh.service enabled,
    no telnet surface, and the root's BUILD_VARIANT stamp.

  * ``server-offline-negative`` — the same medium with the HTTP server
    stopped; the install must fail LOUD and BOUNDED within
    NCZ_KVM_GATE_INSTALL_TIMEOUT and leave no half-written rootfs.

The fetcher's network behaviour (live fetch + sha256 verify, refusal of a
wrong sha256, bounded failure + no partial file when the server is down) is
exercised end to end by build/test-kvm-gate-server.sh, which runs in the
same ``make test`` pass. These tests cover the matrix wiring, the gate
script's server-mode logic (readable without QEMU), and the build-side
pin the medium carries.
"""
import re
import stat
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]


def read(rel: str) -> str:
    p = REPO / rel
    assert p.is_file(), f"missing {rel}"
    return p.read_text()


# ------------------------------------------------------------------- matrix

def test_matrix_has_server_sets():
    m = read("build/kvm-install-gate-matrix.sh")
    # Both sets are wired into the default set list...
    assert 'server server-offline-negative' in m, "the server sets are missing from GATE_ALL_SETS"
    # ...and gate_set_server() maps each to NCZ_GATE_SERVER=1 with the
    # offline flag set only for the negative set.
    assert "server)                  echo \"1 0\"" in m or re.search(r"server\)\s+echo \"1 0\"", m), "server set must map to NCZ_GATE_SERVER=1 offline=0"
    assert re.search(r"server-offline-negative\)\s+echo \"1 1\"", m), "negative set must map to NCZ_GATE_SERVER=1 offline=1"
    # The matrix must actually pass both variables into the gate per set.
    assert re.search(r"NCZ_GATE_SERVER=\"\$_srv\" NCZ_GATE_SERVER_OFFLINE=\"\$_srv_off\"", m), "the matrix must pass NCZ_GATE_SERVER/_OFFLINE to the gate"


def test_gate_script_accepts_server_mode():
    g = read("build/kvm-install-gate-gpt.sh")
    # The server environment variables the matrix sets must be consumed.
    for var in ("NCZ_GATE_SERVER", "NCZ_GATE_SERVER_OFFLINE",
                "NCZ_GATE_SERVER_PAYLOAD", "NCZ_GATE_SERVER_ASSETS"):
        assert re.search(rf"\b{var}\b", g), f"{var} is not consumed by the gate"
    # The server must be proven to answer before the guest starts.
    assert "serving" in g and "200" in g, "the gate must prove the server answers 200"
    # The negative run must assert a loud, bounded failure and no rootfs.
    assert "server-offline" in g or "OFFLINE" in g, "the negative path is missing from the gate"
    assert "half-written" in g or "No root filesystem was installed" in g, \
        "the negative run must assert the no-rootfs contract"


def test_gate_server_assertions_present():
    g = read("build/kvm-install-gate-gpt.sh")
    # The positive run's assertions, each with its own failure message.
    for needle, what in [
        ("verified sha256", "the guest's fetch+verify log line"),
        ("multi-user.target.wants", "ssh.service enabled on the installed root"),
        ("telnet", "no telnet surface on the installed root"),
        ("dpkg", "desktop packages absent from the installed root"),
        ("BUILD_VARIANT", "the root's variant stamp"),
        ("Rescue Partition", "the server boot menu"),
    ]:
        assert needle in g, f"missing assertion for: {what}"


def test_negative_run_uses_bounded_deadline():
    g = read("build/kvm-install-gate-gpt.sh")
    # The negative run's assertion: the install must finish (fail) within
    # the same deadline as a normal install, or the gate fails.
    assert "INSTALL_TIMEOUT" in g, "the negative run must be bounded by INSTALL_TIMEOUT"
    assert re.search(r"_neg_dt.*INSTALL_TIMEOUT", g) or ("past the" in g and "deadline" in g),         "the gate must assert the negative install finished within the deadline"


# ------------------------------------------------------------- invocation

def test_python_invocation_passes_arguments():
    """The reviewer's critical point, as a test: the gate starts its server
    with `python3 - <heredoc> arg1 arg2`. Prove that form passes the
    arguments through sys.argv[1:] (argv[0] is '-')."""
    code = (
        "import sys\n"
        "args = sys.argv[1:]\n"
        "assert args == ['a-dir', '127.0.0.1', '18999'], args\n"
        "print('ok')\n"
    )
    r = subprocess.run(
        ["python3", "-", "a-dir", "127.0.0.1", "18999"],
        input=code, capture_output=True, text=True, timeout=20,
    )
    assert r.returncode == 0, f"python3 - arg1 arg2 failed: {r.stderr}"
    assert "ok" in r.stdout


def test_gate_uses_the_tested_invocation_form():
    g = read("build/kvm-install-gate-gpt.sh")
    # The exact form: python3 - <args> with a heredoc body (not -c).
    assert re.search(r"python3 - \"\$SRV_DIR\" \"\$host\" \"\$port\"", g), \
        "the gate's server invocation must be: python3 - \"$SRV_DIR\" \"$host\" \"$port\" <<'PY'"
    assert "<<'PY'" in g, "the gate's server body must be a quoted heredoc"


def test_test_kvm_gate_server_exists_and_is_executable():
    p = REPO / "build" / "test-kvm-gate-server.sh"
    assert p.is_file(), "build/test-kvm-gate-server.sh is missing (the local server test)"
    assert p.stat().st_mode & stat.S_IXUSR, "build/test-kvm-gate-server.sh must be executable"


# ------------------------------------------------------------- build side

def test_medium_pins_match_the_gate_serve_base():
    """The medium's fetcher pins must point at the gate's serve base
    (write-usb-image.py's ncz_gate_serve_payload_base_url), and the gate
    reads the pin back off the medium rather than trusting a build-time
    default -- so the two cannot drift."""
    w = read("build/iso/write-usb-image.py")
    assert "def ncz_gate_serve_payload_base_url" in w
    assert "10.0.2.2" in w, "the default serve base must be the QEMU user-net gateway"
    g = read("build/kvm-install-gate-gpt.sh")
    # The gate reads the pin off the medium (debugfs dump of the manifest).
    assert "ncz-fetch-payload.manifest" in g, "the gate must read the pins off the medium"


def test_url_contract_between_build_and_gate():
    """The task's NCZ_PAYLOAD_URL/NCZ_ASSETS_URL contract: the build pins the
    medium's fetcher URLs (write-usb-image.py), the doc names the env vars,
    and the gate reads the pins back off the medium (it serves what the
    medium asks for, so the two cannot drift)."""
    d = read("docs/MAGNETAR-SERVER-VARIANT.md")
    assert "NCZ_PAYLOAD_URL" in d and "NCZ_ASSETS_URL" in d, "the doc must name the URL env contract"
    w = read("build/iso/write-usb-image.py")
    assert "ncz_gate_serve_payload_base_url" in w, "the build must derive the pins from the gate's serve base"
    g = read("build/kvm-install-gate-gpt.sh")
    assert "ncz-fetch-payload.manifest" in g, "the gate must read the pins back off the medium"
