#!/bin/bash
# priv.sh -- the ONE documented privilege model for the image build.
#
# The r202 builds each invented their own password-FIFO helper; the mission
# requires a single, documented model with no password FIFOs.  This library is
# it:
#
#   1. already root        -> run the command directly;
#   2. passwordless sudo   -> `sudo <cmd>` (validate with `sudo -n true`);
#   3. otherwise           -> read the fleet sudo password from the master key
#                             file (~/.api_keys_master.json, key
#                             fleet_credentials.sudo_password) with `python3 -I`
#                             and feed it to `sudo -S` ON STDIN.  It is never
#                             written to a file, never passed on a command line,
#                             never echoed, and never logged.
#
#   . build/lib/priv.sh
#   ncz_sudo mount --bind A B        # run as root by the model above
#   ncz_priv_model                   # "root" | "sudo-nopasswd" | "sudo-stdin"
#
# The master key file location can be overridden with NCZ_FLEET_PASS_FILE; the
# JSON key with NCZ_FLEET_PASS_KEY (default fleet_credentials.sudo_password).
# A helper that needs no password may export NCZ_SUDO=0 to force direct exec.
#
# CAVEAT: `sudo -S` consumes one line of the command's stdin for the password.
# Use ncz_sudo only for commands that do not read their own stdin.

NCZ_FLEET_PASS_FILE="${NCZ_FLEET_PASS_FILE:-$HOME/.api_keys_master.json}"
NCZ_FLEET_PASS_KEY="${NCZ_FLEET_PASS_KEY:-fleet_credentials.sudo_password}"

# Print the model that ncz_sudo will use, without running anything privileged.
ncz_priv_model() {
    if [ "$(id -u)" = "0" ]; then printf 'root\n'; return 0; fi
    if [ "${NCZ_SUDO:-1}" = "0" ]; then printf 'direct\n'; return 0; fi
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        printf 'sudo-nopasswd\n'; return 0
    fi
    if [ -f "$NCZ_FLEET_PASS_FILE" ]; then printf 'sudo-stdin\n'; return 0; fi
    printf 'none\n'; return 1
}

# Read the fleet sudo password into a variable without exposing it.  We use a
# dedicated fd (3) so the value never touches argv or a file.  Prints nothing.
_ncz_read_fleet_pass() {
    [ -f "$NCZ_FLEET_PASS_FILE" ] || return 1
    NCZ_FLEET_PASS="$(python3 -I - "$NCZ_FLEET_PASS_FILE" "$NCZ_FLEET_PASS_KEY" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        data = json.load(fh)
except Exception:
    sys.exit(1)
node = data
for part in sys.argv[2].split("."):
    if not isinstance(node, dict) or part not in node:
        sys.exit(1)
    node = node[part]
if not isinstance(node, str) or not node:
    sys.exit(1)
# No newline: sudo -S strips one; we add exactly one when writing.
sys.stdout.write(node)
PYEOF
)" || return 1
    [ -n "$NCZ_FLEET_PASS" ] || return 1
    return 0
}

# Run "$@" as root per the documented model.  Preserves the caller's exit code.
ncz_sudo() {
    if [ "$(id -u)" = "0" ]; then "$@"; return $?; fi
    if [ "${NCZ_SUDO:-1}" = "0" ]; then "$@"; return $?; fi
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        sudo -- "$@"; return $?
    fi
    if ! _ncz_read_fleet_pass; then
        echo "priv.sh: no passwordless sudo and cannot read $NCZ_FLEET_PASS_KEY from $NCZ_FLEET_PASS_FILE" >&2
        echo "priv.sh: grant passwordless sudo for this account, run as root, or provide the master key file" >&2
        return 1
    fi
    # _ncz_read_fleet_pass populates NCZ_FLEET_PASS; feed THAT to sudo -S (a
    # separate local alias was never assigned here -- zoder caught it).
    printf '%s\n' "$NCZ_FLEET_PASS" | sudo -S -p '' -- "$@"
    local rc=$?
    unset NCZ_FLEET_PASS
    return $rc
}

# Run a whole command STRING as root (for callers that build a shell line).
ncz_sudo_bash() {
    local line="$1"; shift
    ncz_sudo bash -c "$line" "$@"
}

# ---------------------------------------------------------------------------
# Hand privileged build artifacts back to the invoking (non-root) user.
#
# WHY (operator 2026-10-11 "fix open items").  The KVM install gate and the
# provenance gate run through ncz_sudo (as root).  Everything they write under
# the run dir -- kvm-gate/ui-check/, kvm-gate/target-logs/, prov-index/ -- is
# then owned by root, so the build user cannot `rm -rf` a finished run dir
# (36G stranded on ACHILLES; same class as the arm64 .kdebs-tmp stray logs).
# Each privileged script installs an exit trap that chowns its OWN work output
# back to the invoker on EVERY exit path (normal, error, signal).  This is
# cleanup only: it runs after the gate decision and never changes it -- the
# EXIT trap preserves the exit status.
#
# Target uid:gid, in order of preference:
#   * NCZ_CHOWN_BACK     -- set explicitly by build-image.sh while it builds the
#                           sudo command line, so it works when the whole build
#                           runs as the root login too (sudo's env_reset would
#                           otherwise drop a plain environment variable);
#   * SUDO_UID/SUDO_GID  -- sudo always exports these to the command it runs;
#   * otherwise nothing  -- we ARE the root login, root-owned is already right.
# ---------------------------------------------------------------------------
ncz_chown_target() {
    if [ -n "${NCZ_CHOWN_BACK:-}" ]; then printf '%s\n' "$NCZ_CHOWN_BACK"; return 0; fi
    if [ -n "${SUDO_UID:-}" ]; then printf '%s:%s\n' "$SUDO_UID" "${SUDO_GID:-$SUDO_UID}"; return 0; fi
    return 1
}

# chown DIR... back to the invoking user. Root-only; never fails the caller and
# never reads a gate verdict.  NCZ_CHOWN_BACK_FORCE=1 lets the regression test
# drive it as a normal user (with a stub chown); it only affects cleanup.
ncz_chown_back() {
    if [ "${NCZ_CHOWN_BACK_FORCE:-0}" != "1" ] && [ "$(id -u)" != "0" ]; then return 0; fi
    local target; target="$(ncz_chown_target)" || return 0
    [ -n "$target" ] || return 0
    local d
    for d in "$@"; do
        [ -e "$d" ] || continue
        chown -R "$target" "$d" 2>/dev/null || true
    done
    return 0
}

# Install the chown-back trap for DIR... (call once, early, BEFORE the script
# creates anything as root).  Chowns on normal exit, `exit N`, errexit, and the
# usual signals; the EXIT handler restores the original status so a gate verdict
# is never altered by cleanup.
ncz_trap_chown_back() {
    NCZ_CHOWN_BACK_DIRS=("$@")
    # Chain any pre-existing EXIT trap instead of silently dropping its cleanup
    # (zoder review 2026-10-11).  `trap -p EXIT` prints: trap -- 'CMD' EXIT
    NCZ_CHOWN_BACK_PREV_CMD=""
    local prev; prev="$(trap -p EXIT 2>/dev/null || true)"
    # Only accept bash's canonical `trap -- 'CMD' EXIT` form; any other shape is
    # left unchained, so eval never sees an unrecognised string.  All three
    # callers set no EXIT trap of their own, so this is purely defensive.
    case "$prev" in
        "trap -- '"*"' EXIT")
            NCZ_CHOWN_BACK_PREV_CMD="${prev#trap -- \'}"
            NCZ_CHOWN_BACK_PREV_CMD="${NCZ_CHOWN_BACK_PREV_CMD%\' EXIT}" ;;
    esac
    _ncz_chown_back_trap() {
        local rc=$?
        [ -n "$NCZ_CHOWN_BACK_PREV_CMD" ] && { eval "$NCZ_CHOWN_BACK_PREV_CMD" || true; }
        ncz_chown_back "${NCZ_CHOWN_BACK_DIRS[@]}"
        return "$rc"
    }
    trap '_ncz_chown_back_trap' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
}
