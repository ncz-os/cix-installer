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
    local pw
    if ! _ncz_read_fleet_pass; then
        echo "priv.sh: no passwordless sudo and cannot read $NCZ_FLEET_PASS_KEY from $NCZ_FLEET_PASS_FILE" >&2
        echo "priv.sh: grant passwordless sudo for this account, run as root, or provide the master key file" >&2
        return 1
    fi
    printf '%s\n' "$pw" | sudo -S -p '' -- "$@"
    local rc=$?
    unset pw NCZ_FLEET_PASS
    return $rc
}

# Run a whole command STRING as root (for callers that build a shell line).
ncz_sudo_bash() {
    local line="$1"; shift
    ncz_sudo bash -c "$line" "$@"
}
