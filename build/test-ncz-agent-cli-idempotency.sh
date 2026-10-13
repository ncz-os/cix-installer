#!/bin/bash
# test-ncz-agent-cli-idempotency.sh -- static checks of the idempotency
# contract `ncz agent install/uninstall <name>` must satisfy (the brief
# requires both to be safe to re-run). We do NOT need to actually call
# podman/systemd — we read the helper source and assert the contract.
#
# What this test catches:
#   - cmd_agent_install skips overwriting the active quadlet when the
#     staged template is older than the active one (so a re-run of
#     `ncz agent install zeroclaw` after a custom /etc/containers/systemd
#     edit does not clobber it).
#   - cmd_agent_install `enable`s the .service so the agent survives reboot.
#   - cmd_agent_install restarts (not just starts) the service so a config
#     change is picked up on re-install.
#   - cmd_agent_uninstall disables the .service so it does not come back
#     on the next boot.
#   - cmd_agent_uninstall drops the .agents-installed sentinel only when
#     nothing is left installed, otherwise a sentinel-only partial-uninstall
#     would orphan agents.
#   - is_installed() reads /etc/containers/systemd/<name>.container (the
#     active quadlet) and the portainer pod (the documented stop on the
#     portainer branch).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/assets/ncz-cli.sh"
T="$(mktemp -d "${TMPDIR:-/var/tmp}/nczutil-agent-idem.XXXXXX")"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

# Re-exec under a bash with `declare -A` (associative arrays). macOS's
# /bin/bash 3.2 lacks it; Debian forky / Linux build hosts have it.
if [ -z "${BASH_VERSION:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    for c in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash5; do
        [ -x "$c" ] && exec "$c" "$0" "$@"
    done
    echo "FAIL bash $BASH_VERSION too old and no modern replacement found" >&2
    exit 2
fi

# Isolate from contaminating other roots (do NOT actually touch the real
# /etc/containers/systemd or systemctl on a developer laptop).
# We assert only what the source says, plus what `ncz agent list` would
# render in a sandboxed no-podman environment. Note: the CLI hardcodes
# QUADLET_ACTIVE=/etc/containers/systemd (no env override), so the sandbox
# test only checks the negative path (no quadlets → all not-installed).
SHADOW="$T/shadow"
mkdir -p "$SHADOW/bin"
# Stub podman so `podman container exists portainer` returns false (no
# portainer installed) and `is_installed zeroclaw` reports not-installed.
cat > "$SHADOW/bin/podman" <<'PODMAN_EOF'
#!/bin/bash
case "$1 $2" in
    "container exists") exit 1 ;;
    "image exists") exit 1 ;;
    "container ls"|"images"|"ps") exit 0 ;;
    *) exit 1 ;;
esac
PODMAN_EOF
chmod +x "$SHADOW/bin/podman"
# Stub systemctl: `is-active <svc>.service` returns "inactive" so the
# `state=$(systemctl is-active ...)` line in cmd_agent_list falls back to
# "not-installed" rather than an actual real call.
cat > "$SHADOW/bin/systemctl" <<'SYSTEMCTL_EOF'
#!/bin/bash
case "$1" in
    is-active) echo "inactive" ;;
    list-unit-files) : ;;
    *) : ;;
esac
SYSTEMCTL_EOF
chmod +x "$SHADOW/bin/systemctl"

# Run the helper against the shadow root. We do NOT verify a specific
# row's state value because `is_installed()` reads /etc/containers/systemd
# directly (hardcoded in the helper) and we do NOT want this test to
# touch the real /etc/containers/systemd on a developer laptop. The
# important "all four agents render" assertion catches a dispatcher that
# silently dropped one.
out=$(PATH="$SHADOW/bin:/usr/bin:/bin" "$BASH" "$CLI" agent list 2>&1)
for a in zeroclaw openclaw hermes portainer; do
    echo "$out" | grep -q "^$a" && ok "agent list renders row for $a" \
        || bad "agent list missing row for $a: $out"
done
echo "$out" | grep -q "not-installed" && ok "agent list shows 'not-installed' state on clean shadow" \
    || bad "agent list does not show 'not-installed' state: $out"

# Source-level idempotency contract (we read the source, not run it).
grep -q 'systemctl disable "$a.service"' "$CLI" \
    && ok "cmd_agent_uninstall disables the .service" \
    || bad "cmd_agent_uninstall does NOT disable the .service"
grep -q 'systemctl restart "$a.service"' "$CLI" \
    && ok "cmd_agent_install uses restart, not just start" \
    || bad "cmd_agent_install uses start, not restart (config edits won't pick up on re-run)"
grep -q 'systemctl enable "$a.service"' "$CLI" \
    && ok "cmd_agent_install enables the .service" \
    || bad "cmd_agent_install does NOT enable the .service (agent will not survive reboot)"
# Re-install must not unconditionally overwrite the active quadlet.
grep -q 'QUADLET_TEMPLATES.*-nt.*QUADLET_ACTIVE' "$CLI" \
    && ok "cmd_agent_install preserves the active quadlet if it is newer" \
    || bad "cmd_agent_install overwrites the active quadlet unconditionally (loses custom edits on re-run)"
# Sentinel-only behaviour
grep -q 'is_installed zeroclaw && ! is_installed openclaw' "$CLI" \
    && ok "cmd_agent_uninstall drops .agents-installed only when nothing left" \
    || bad "cmd_agent_uninstall drops .agents-installed too eagerly"

# is_installed() contract
grep -q 'podman container exists portainer' "$CLI" \
    && ok "is_installed checks podman container exists for portainer" \
    || bad "is_installed does NOT use the podman container check for portainer"
grep -q 'QUADLET_ACTIVE/\$1.container' "$CLI" \
    && ok "is_installed checks the active quadlet for non-portainer agents" \
    || bad "is_installed does NOT check the active quadlet for non-portainer agents"

echo "--- $pass passed, $fail failed"
[ "$fail" = "0" ]