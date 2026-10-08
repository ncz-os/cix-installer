#!/usr/bin/env bash
# test-single-preseed.sh -- one-load preseed regressions.
#
# The 2026-10-08 fix removes preseed/file=... from the Install entry so d-i's
# own S30initrd-preseed is the ONLY load of the baked /preseed.cfg. This test
# proves the pieces that can be proven without a boot:
#
#   A. every Install entry carries no preseed/file=, still carries auto=true,
#      and the Expert/Rescue entries carry neither (both arches).
#   B. with the REAL upstream S30/S33/S60 fixtures (sandboxed, paths rewritten
#      in the sandbox only) sourced in d-i's lexical order: exactly one
#      preseed_location and one preseed/early_command, and the baked
#      S61ncz-preseed-reenable hook restores auto-install.active=0. Also proves
#      a `echo 0` at S33 (early_command) cannot work -- S60 overwrites it -- and
#      that Expert/Rescue (auto-install/enable != true) leave the file absent.
#   C. the real file-preseed.isinstallable exits 1 when preseed/file is empty,
#      so the second load cannot happen.
#   D. patch-initrd-t2-kernel.py now FAILS (exits 1) on a missing preseed path
#      instead of downgrading it to a warning.
#   E. verify_baked_preseed() reads the FINAL cpio back: a matching
#      /preseed.cfg + executable hook passes, mismatched bytes fail.
#
# Runs on Linux with GNU cpio. Sandbox is under the project-local tmp dir
# (default <repo>/.test-tmp, never /tmp).
set -u
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
FIX="$HERE/fixtures/d-i-startup"
PATCHER="$REPO/build/iso/patch-initrd-t2-kernel.py"
ESP="$REPO/build/iso/build-refind-esp.py"

PASS=0; FAIL=0; SKIP=0
ok()   { echo "PASS  $1"; PASS=$((PASS + 1)); }
bad()  { echo "FAIL  $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP  $1"; SKIP=$((SKIP + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }

# ---------------------------------------------------------------- platform gate
# This test packs/reads newc cpio with GNU cpio and hashes fixtures with GNU
# coreutils. On a non-GNU host (macOS/BSD cpio, busybox cpio) those commands
# either do not exist or reject GNU flags, so SKIP explicitly up front instead
# of failing a GNU-only command and reporting a false PASS/FAIL.
HAVE_GNU_CPIO=0
if command -v cpio >/dev/null 2>&1 && cpio --version 2>/dev/null | grep -q 'GNU'; then
    HAVE_GNU_CPIO=1
fi
if ! command -v sha256sum >/dev/null 2>&1 || [ "$HAVE_GNU_CPIO" != 1 ]; then
    echo "SKIP  test-single-preseed: needs GNU coreutils sha256sum + GNU cpio (host: $(uname -s))"
    echo "single-preseed tests: 0 passed, 0 failed, 1 skipped"
    exit 0
fi

TMPROOT="${NCZ_TEST_TMPDIR:-$REPO/.test-tmp}"
mkdir -p "$TMPROOT" || { echo "cannot create TMPROOT $TMPROOT" >&2; exit 2; }
WORK="$(mktemp -d "$TMPROOT/single-preseed.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------- fixture integrity
# The vendored upstream scripts must be the real bytes the README records.
verify_sha() {  # path expected
    local got
    got="$(sha256sum "$1" 2>/dev/null | awk '{print $1}')"
    check "fixture $(basename "$1") is the recorded upstream bytes" "$got" "$2"
}
verify_sha "$FIX/amd64/S30initrd-preseed" "f58151f324dca1c2ab7d4e5f6ea00fadc5f528bb557dc95d692619d0e4e0d909"
verify_sha "$FIX/amd64/S33preseed_early_command" "14d262783aa4b861afc0727a147da543ed68dc52e0e2439329c4e30b177f8c4f"
verify_sha "$FIX/arm64/S60auto-install" "1ad20dcaca5d61aa5734d6f6049cbc3b33f80d134f832e54afe6580a0699c4dd"
verify_sha "$FIX/file-preseed.isinstallable" "1efc378303cb071bc479f96a5369ea06700d8b94075af9002b658ca9a5a97265"

# ---------------------------------------------------------------- A. cmdline
if python3 - "$ESP" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("esp", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
problems = []
for name in ("_PC_INSTALL_OPTIONS", "AMD64_INSTALL_OPTIONS", "ARM64_INSTALL_OPTIONS"):
    opts = getattr(m, name)
    toks = opts.split()
    if any(t.startswith("preseed/file") for t in toks):
        problems.append(f"{name}: still carries preseed/file")
    if toks.count("auto=true") != 1:
        problems.append(f"{name}: auto=true count {toks.count('auto=true')} != 1")
for name in ("_PC_EXPERT_OPTIONS", "AMD64_EXPERT_OPTIONS",
             "ARM64_EXPERT_OPTIONS", "_PC_RESCUE_OPTIONS",
             "AMD64_RESCUE_OPTIONS", "ARM64_RESCUE_OPTIONS"):
    opts = getattr(m, name)
    if "preseed/file" in opts:
        problems.append(f"{name}: carries preseed/file")
    if "auto=true" in opts:
        problems.append(f"{name}: carries auto=true")
if problems:
    print("\n".join(problems))
    sys.exit(1)
print("OK")
PY
then ok "A: Install entries have no preseed/file, auto=true on Install only (both arches)"; else bad "A: refind install options wrong"; fi

# ---------------------------------------------------------------- B/C. sandbox
HOOK_NAME="$(python3 - "$PATCHER" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("patcher", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(m.NCZ_STARTUP_HOOK_NAME)
PY
)"

sandbox_arch() {  # arch -> builds $WORK/sb-<arch>; echoes sandbox dir
    local arch="$1" sb="$WORK/sb-$1"
    mkdir -p "$sb/usr/lib/debian-installer-startup.d" "$sb/lib/preseed" \
             "$sb/usr/share/debconf" "$sb/var/run" "$sb/bin"
    : > "$sb/preseed.cfg"
    local s
    for s in S30initrd-preseed S33preseed_early_command S60auto-install; do
        sed -e "s#/preseed\.cfg#$sb/preseed.cfg#g" \
            -e "s#/lib/preseed/preseed\.sh#$sb/lib/preseed/preseed.sh#g" \
            -e "s#/usr/share/debconf/confmodule#$sb/usr/share/debconf/confmodule#g" \
            -e "s#/var/run/#$sb/var/run/#g" \
            "$FIX/$arch/$s" > "$sb/usr/lib/debian-installer-startup.d/$s"
    done
    # hook: real body from the patcher, sandbox-substituted
    python3 - "$PATCHER" "$sb" <<'PY'
import importlib.util, sys, pathlib
spec = importlib.util.spec_from_file_location("patcher", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
sb = pathlib.Path(sys.argv[2])
body = (m.NCZ_STARTUP_HOOK_BODY
        .replace("/var/run/", str(sb / "var" / "run") + "/")
        .replace("/preseed.cfg", str(sb / "preseed.cfg")))
d = sb / "usr/lib/debian-installer-startup.d"
p = d / m.NCZ_STARTUP_HOOK_NAME
p.write_text(body)
p.chmod(0o755)
PY
    # stubs for the sourced d-i library and debconf
    cat > "$sb/lib/preseed/preseed.sh" <<EOF
preseed_location() { printf 'LOAD:%s\n' "\$1" >> "$sb/var/run/trace"; }
EOF
    cat > "$sb/usr/share/debconf/confmodule" <<EOF
db_get() {
    case "\$1" in
        auto-install/enable) RET="\${FAKE_AUTO:-true}" ;;
        preseed/file) RET="\${FAKE_PRESEED_FILE:-}" ;;
        *) RET="" ;;
    esac
    return 0
}
EOF
    cat > "$sb/bin/preseed_command" <<EOF
#!/bin/sh
printf 'CMD:%s\n' "\$1" >> "$sb/var/run/trace"
EOF
    chmod +x "$sb/bin/preseed_command"
    echo "$sb"
}

# run_order SB SEQ... -- each S* is a separate process (d-i's real model; S60's
# `exit 0` must not abort the sequence).
run_order() {
    local sb="$1"; shift
    rm -f "$sb/var/run/auto-install.active" "$sb/var/run/trace" \
          "$sb/var/run/preseed_unspecified_at_boot"
    local s
    for s in "$@"; do
        PATH="$sb/bin:$PATH" sh "$sb/usr/lib/debian-installer-startup.d/$s" >/dev/null 2>&1 || true
    done
}

active_of() { cat "$1/var/run/auto-install.active" 2>/dev/null || echo "ABSENT"; }
trace_loads() { grep -c '^LOAD:' "$1/var/run/trace" 2>/dev/null || true; }
trace_cmds() { grep -c '^CMD:' "$1/var/run/trace" 2>/dev/null || true; }

for arch in amd64 arm64; do
    sb="$(sandbox_arch "$arch")"
    export FAKE_AUTO=true FAKE_PRESEED_FILE=""

    run_order "$sb" S30initrd-preseed S33preseed_early_command S60auto-install "$HOOK_NAME"
    check "B[$arch]: one preseed load" "$(trace_loads "$sb")" "1"
    check "B[$arch]: one preseed/early_command" "$(trace_cmds "$sb")" "1"
    check "B[$arch]: S61 hook restores auto-install.active=0" "$(active_of "$sb")" "0"

    run_order "$sb" S30initrd-preseed S33preseed_early_command S60auto-install
    check "B[$arch]: without the hook S60 leaves active=1 (a S33 echo 0 is overwritten)" "$(active_of "$sb")" "1"

    run_order "$sb" S30initrd-preseed S33preseed_early_command "$HOOK_NAME" S60auto-install
    check "B[$arch]: hook BEFORE S60 is overwritten to 1 (placement matters)" "$(active_of "$sb")" "1"

    export FAKE_AUTO=false
    run_order "$sb" S30initrd-preseed S33preseed_early_command S60auto-install "$HOOK_NAME"
    check "B[$arch]: Expert/Rescue (no auto) leave auto-install.active ABSENT" "$(active_of "$sb")" "ABSENT"
    export FAKE_AUTO=true

    # C. real file-preseed.isinstallable
    sed "s#/usr/share/debconf/confmodule#$sb/usr/share/debconf/confmodule#g" \
        "$FIX/file-preseed.isinstallable" > "$sb/file-preseed.isinstallable"
    FAKE_PRESEED_FILE="" sh "$sb/file-preseed.isinstallable" >/dev/null 2>&1
    check "C[$arch]: file-preseed NOT installable with preseed/file empty (no second load)" "$?" "1"
    FAKE_PRESEED_FILE="/cdrom/ncz-payload/preseed.cfg" sh "$sb/file-preseed.isinstallable" >/dev/null 2>&1
    check "C[$arch]: file-preseed installable when preseed/file is set (mechanism intact)" "$?" "0"
done

# ---------------------------------------------------------------- D. patcher guard
if command -v python3 >/dev/null 2>&1; then
    out="$(python3 "$PATCHER" --base-initrd /dev/null --kernel-deb /dev/null \
           --arch amd64 --cache-root "$WORK/cache" \
           --preseed-cfg "$WORK/definitely-absent.cfg" 2>&1)"
    rc=$?
    if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'FATAL: a real --preseed-cfg file is required'; then
        ok "D: missing --preseed-cfg path is now FATAL (rc=$rc), not a warning"
    else
        bad "D: missing preseed path did not fail as required (rc=$rc): $out"
    fi
else
    skip "D: python3 not available"
fi

# ---------------------------------------------------------------- E. cpio verify
if command -v gzip >/dev/null 2>&1; then
    if python3 - "$PATCHER" "$WORK" <<'PY'
import gzip, importlib.util, pathlib, subprocess, sys

spec = importlib.util.spec_from_file_location("patcher", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
work = pathlib.Path(sys.argv[2])


def pack_tree(tree, out_gz):
    names = sorted(p.relative_to(tree).as_posix()
                   for p in tree.rglob("*") if p.is_file())
    cpio = subprocess.run(["cpio", "-o", "-H", "newc", "--quiet"], cwd=tree,
                          input=("\n".join(names) + "\n").encode(),
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                          check=True)
    with gzip.open(out_gz, "wb") as fh:
        fh.write(cpio.stdout)


base = work / "v-base"
base.mkdir()
(base / "base-marker").write_text("base\n")
base_gz = work / "v-base.cpio.gz"
pack_tree(base, base_gz)

overlay = work / "v-overlay"
hook_dir = overlay / "usr/lib/debian-installer-startup.d"
hook_dir.mkdir(parents=True)
src = work / "v-preseed-src.cfg"
src.write_text("# preseed A\nnetcfg/get_hostname string x\n")
(overlay / "preseed.cfg").write_text(src.read_text())
hook = hook_dir / m.NCZ_STARTUP_HOOK_NAME
hook.write_text(m.NCZ_STARTUP_HOOK_BODY)
hook.chmod(0o755)
overlay_gz = work / "v-overlay.cpio.gz"
pack_tree(overlay, overlay_gz)

out = work / "v-initrd.gz"
m.write_single_member_initrd(base_gz, overlay_gz, out)
info = m.verify_baked_preseed(out, src)
if info["hook_mode"] != "0755":
    raise SystemExit(f"hook mode {info['hook_mode']} != 0755")

bad = work / "v-preseed-bad.cfg"
bad.write_text("# different bytes\n")
try:
    m.verify_baked_preseed(out, bad)
except RuntimeError:
    pass
else:
    raise SystemExit("mismatched preseed did NOT fail verification")
print("OK")
PY
    then ok "E: verify_baked_preseed accepts a matching cpio and rejects mismatched bytes"; else bad "E: cpio verification test failed"; fi
else
    skip "E: GNU cpio/gzip not available"
fi

echo "single-preseed tests: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" = 0 ]
