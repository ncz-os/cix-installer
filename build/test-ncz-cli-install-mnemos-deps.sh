#!/bin/bash
# test-ncz-cli-install-mnemos-deps.sh -- assert the ncz install mnemos +
# ncz agent install paths pull every package they need at runtime, and
# that the on-disk quadlet templates / agent assets the install relies on
# exist in the repo.
#
# Why static: we want this gate to be fast and reproducible on the build
# host (Debian, bash 5.x). It does NOT need to run on a real NCZ-OS
# install. It DOES need to be run inside the repo so it can read manifests/.
#
# What this test catches:
#   - manifests/desktop.pkms declares uidmap, slirp4netns, fuse-overlayfs
#     (rootless podman helpers — verified missing on PEGASUS .85, O6N .3,
#     MS-R1 .66 by the orchestrator on 2026-10-13)
#   - manifests/desktop-amd64.pkms declares the same trio (AMD64 builds
#     need them too: podman rootless without newuidmap fails identically)
#   - post-install/46-ncz-cli.sh references the install-time staging
#     locations used by `ncz install mnemos` (asset staging path under
#     /usr/share/ncz/quadlets + the sudoers.d secure_path fix)
#   - post-install/46-ncz-cli.sh installs /etc/sudoers.d/ncz-cli-secure-path
#     so `sudo ncz` resolves (verified: sudo: ncz: command not found on
#     PEGASUS .85 / O6N .3 / MS-R1 .66 on 2026-10-13)
#   - post-install/46-ncz-cli.sh stages assets/agent-stack/*.container into
#     /usr/share/ncz/quadlets/ at install time (so `ncz install mnemos` on a
#     freshly-installed box does not error out with "missing quadlet template")
#   - assets/agent-stack/mnemos.container has Pull=never (quadlet must NOT
#     reach for the network at runtime)
#   - assets/agent-stack/mnemos.container uses Network=host (Sky1 kernel
#     does not build veth/bridge — verified on MS-R1 .66 2026-07)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

# Manifest closure: every package the install path relies on at runtime must
# be seeded on both arches. We grep -E '^<name>$' to require the bare
# package name in a non-comment line (the manifest format is one
# package-name per line; comments start with #).
assert_pkg_in_manifest() {
        local manifest="$1" pkg="$2" why="$3"
        if grep -E "^${pkg}$" "$ROOT/manifests/$manifest" >/dev/null 2>&1; then
                ok "$manifest declares '$pkg' ($why)"
        else
                bad "$manifest is missing '$pkg' ($why)"
        fi
    }

# Rootless podman helpers (the failure mode observed on every test host
# on 2026-10-13: "podman info" as user ncz failed with
# `exec: "newuidmap": executable file not found in $PATH`).
assert_pkg_in_manifest desktop.pkgs         uidmap         "rootless uid/gid mapping"
assert_pkg_in_manifest desktop.pkgs         slirp4netns    "rootless NAT (no host-bridge on Sky1)"
assert_pkg_in_manifest desktop.pkgs         fuse-overlayfs "rootless overlayfs"
assert_pkg_in_manifest desktop-amd64.pkgs   uidmap         "rootless uid/gid mapping"
assert_pkg_in_manifest desktop-amd64.pkgs   slirp4netns    "rootless NAT"
assert_pkg_in_manifest desktop-amd64.pkgs   fuse-overlayfs "rootless overlayfs"

# Podman + helpers that `ncz install mnemos` and `ncz agent install` call
# as root. Already present in both manifests per the r181 audit, but assert
# them so a future refactor cannot silently drop them.
for pkg in podman crun conmon netavark aardvark-dns catatonit whiptail; do
    assert_pkg_in_manifest desktop.pkgs       "$pkg" "agent-stack runtime"
    assert_pkg_in_manifest desktop-amd64.pkgs "$pkg" "agent-stack runtime"
done

# post-install/46-ncz-cli.sh — the three guards the orchestrator verified
# were missing on 2026-10-13.
HOOK="$ROOT/post-install/46-ncz-cli.sh"
[ -f "$HOOK" ] && ok "post-install/46-ncz-cli.sh exists" || bad "post-install/46-ncz-cli.sh missing"

# Guard 1: sudoers secure_path so `sudo ncz` resolves.
grep -q 'ncz-cli-secure-path' "$HOOK" && ok "post-install drops /etc/sudoers.d/ncz-cli-secure-path" \
    || bad "post-install does NOT install sudoers.d/ncz-cli-secure-path (sudo ncz will fail)"
grep -q 'secure_path = "/usr/local/sbin:/usr/local/bin:' "$HOOK" \
    && ok "sudoers snippet sets secure_path with /usr/local/bin" \
    || bad "sudoers snippet does not put /usr/local/bin in secure_path"
grep -q 'chmod 0440' "$HOOK" && ok "sudoers snippet chmod 0440 (sudo-required mode)" \
    || bad "sudoers snippet missing chmod 0440"
grep -q 'chown root:root' "$HOOK" && ok "sudoers snippet chown root:root" \
    || bad "sudoers snippet missing chown root:root"

# Guard 2: stage the quadlet templates at install time so ncz install
# mnemos works on a fresh system.
grep -q '/usr/share/ncz/quadlets' "$HOOK" && ok "post-install stages /usr/share/ncz/quadlets" \
    || bad "post-install does NOT stage /usr/share/ncz/quadlets"
grep -q 'agent-stack' "$HOOK" && ok "post-install pulls from assets/agent-stack" \
    || bad "post-install does NOT reference assets/agent-stack"
grep -q 'install -D -m 0644' "$HOOK" && ok "post-install uses install -D -m 0644 (idempotent staging)" \
    || bad "post-install missing install -D for templates"

# Guard 3: the offline image fallback prints a helpful error message when
# BOTH the bundled archive is absent AND the network pull fails.
grep -q 'no bundled image at:' "$HOOK" && ok "post-install prints the offline-image diagnostic" \
    || bad "post-install does NOT print the offline-image diagnostic"
grep -q 'podman pull.*attempt' "$HOOK" && ok "post-install retries podman pull (transient 5xx)" \
    || bad "post-install does NOT retry the network pull"

# Guard 4: MNEMOS internal-audit-token bootstrap + first-run api_key issuance.
grep -q 'MNEMOS_INTERNAL_AUDIT_TOKEN' "$HOOK" && ok "post-install generates MNEMOS_INTERNAL_AUDIT_TOKEN" \
    || bad "post-install does NOT generate MNEMOS_INTERNAL_AUDIT_TOKEN"
grep -q 'X-Mnemos-Audit-Token' "$HOOK" && ok "post-install uses X-Mnemos-Audit-Token for bootstrap" \
    || bad "post-install does NOT use X-Mnemos-Audit-Token"
grep -q 'mnemos.env' "$HOOK" && ok "post-install writes /etc/nclawzero/mnemos.env" \
    || bad "post-install does NOT write /etc/nclawzero/mnemos.env"

# Guard 5: IDEMPOTENCY markers in ncz_install_mnemos.
grep -q 'image already present' "$HOOK" && ok "ncz install mnemos idempotent: skips pull when image exists" \
    || bad "ncz install mnemos does NOT skip pull when image present"
grep -q 'active quadlet already exists' "$HOOK" && ok "ncz install mnemos idempotent: preserves existing quadlet" \
    || bad "ncz install mnemos does NOT preserve existing quadlet"
grep -q 'MNEMOS API token already provisioned' "$HOOK" && ok "ncz install mnemos idempotent: skips api-key re-issue" \
    || bad "ncz install mnemos does NOT skip api-key re-issue"

# Quadlet-template contract: must NOT reach for the network and MUST use
# host networking on Sky1.
QUAD="$ROOT/assets/agent-stack/mnemos.container"
grep -q '^Pull=never' "$QUAD" && ok "mnemos.container has Pull=never" \
    || bad "mnemos.container missing Pull=never"
grep -q '^Network=host' "$QUAD" && ok "mnemos.container has Network=host (Sky1 has no veth/bridge)" \
    || bad "mnemos.container missing Network=host"
grep -q 'MNEMOS_PERSISTENCE_BACKEND=sqlite' "$QUAD" && ok "mnemos.container sets sqlite backend" \
    || bad "mnemos.container missing sqlite backend"
grep -q 'mnemos-data:/data:Z' "$QUAD" && ok "mnemos.container mounts mnemos-data:/data (sqlite persists)" \
    || bad "mnemos.container missing mnemos-data volume mount"

# agent-stack closure: every documented agent has a quadlet template.
for tpl in zeroclaw openclaw hermes mnemos nemoclaw; do
    [ -f "$ROOT/assets/agent-stack/$tpl.container" ] \
        && ok "quadlet template $tpl.container present" \
        || bad "quadlet template $tpl.container missing"
done
[ -f "$ROOT/assets/agent-stack/agent-env.sample" ] \
    && ok "agent-env.sample present" \
    || bad "agent-env.sample missing"

echo "--- $pass passed, $fail failed"
[ "$fail" = "0" ]