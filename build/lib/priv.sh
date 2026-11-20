#!/bin/bash
# priv.sh -- the ONE documented privilege model for the image build.
#
# The r202 builds each invented their own password-FIFO helper; the mission
# requires a single, documented model with no password FIFOs.  This library is
# it:
#
#   1. already root        -> run the command directly;
#   2. passwordless sudo   -> `sudo <cmd>` (validate with `sudo -n true`);
#   3. otherwise           -> read the sudo password from a JSON file named by
#                             NCZ_SUDO_PASS_FILE (or the first line of
#                             ~/.config/ncz/sudo-pass-file), key NCZ_SUDO_PASS_KEY
#                             (default sudo_password), with `python3 -I`
#                             and feed it to `sudo -S` ON STDIN.  It is never
#                             written to a file, never passed on a command line,
#                             never echoed, never logged, and never xtraced
#                             (the secret-bearing region runs with `set +x`
#                             even when the caller has xtrace on).
#
#   . build/lib/priv.sh
#   ncz_sudo mount --bind A B        # run as root by the model above
#   ncz_priv_model                   # "root" | "sudo-nopasswd" | "sudo-stdin"
#
# NCZ_SUDO_PASS_KEY may be a dotted path into the JSON (also settable through
# ~/.config/ncz/sudo-pass-key).
# A helper that needs no password may export NCZ_SUDO=0 to force direct exec.
#
# CAVEAT: `sudo -S` consumes one line of the command's stdin for the password.
# Use ncz_sudo only for commands that do not read their own stdin.

_ncz_priv_cfg() { local f="${XDG_CONFIG_HOME:-${HOME:-}/.config}/ncz/$1"; [ -r "$f" ] && head -n1 "$f" | tr -d "[:space:]"; return 0; }
NCZ_SUDO_PASS_FILE="${NCZ_SUDO_PASS_FILE:-$(_ncz_priv_cfg sudo-pass-file)}"
NCZ_SUDO_PASS_KEY="${NCZ_SUDO_PASS_KEY:-$(_ncz_priv_cfg sudo-pass-key)}"
NCZ_SUDO_PASS_KEY="${NCZ_SUDO_PASS_KEY:-sudo_password}"

# Print the model that ncz_sudo will use, without running anything privileged.
ncz_priv_model() {
    if [ "$(id -u)" = "0" ]; then printf 'root\n'; return 0; fi
    if [ "${NCZ_SUDO:-1}" = "0" ]; then printf 'direct\n'; return 0; fi
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        printf 'sudo-nopasswd\n'; return 0
    fi
    if [ -n "$NCZ_SUDO_PASS_FILE" ] && [ -f "$NCZ_SUDO_PASS_FILE" ]; then printf 'sudo-stdin\n'; return 0; fi
    printf 'none\n'; return 1
}

# xtrace (`set -x` / `bash -x`) traces every expansion -- including the
# NCZ_SUDO_PASS assignment and the `printf` that feeds `sudo -S`, so any caller
# debugging a failed step with `bash -x` would leak the sudo-pass file content
# into the build log (2026-11-13 side finding, cycle 232).  The secret-bearing
# region below therefore runs with xtrace forced off and the caller's setting
# restored on every exit path.
_ncz_secret_begin() {
    _NCZ_XTRACE_RESTORE=""
    case "$-" in *x*) _NCZ_XTRACE_RESTORE="set -x"; set +x ;; esac
}
_ncz_secret_end() {
    if [ -n "${_NCZ_XTRACE_RESTORE:-}" ]; then
        eval "$_NCZ_XTRACE_RESTORE"
        _NCZ_XTRACE_RESTORE=""
    fi
    return 0
}

# Read the sudo password into a variable without exposing it.  The value is
# captured from python3's stdout only; nothing is traced, and error paths stay
# silent.  Prints nothing.
_ncz_read_sudo_pass() {
    [ -f "$NCZ_SUDO_PASS_FILE" ] || return 1
    _ncz_secret_begin
    NCZ_SUDO_PASS="$(python3 -I - "$NCZ_SUDO_PASS_FILE" "$NCZ_SUDO_PASS_KEY" <<'PYEOF'
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
)" || { _ncz_secret_end; return 1; }
    [ -n "$NCZ_SUDO_PASS" ] || { _ncz_secret_end; return 1; }
    _ncz_secret_end
    return 0
}

# Run "$@" as root per the documented model.  Preserves the caller's exit code.
ncz_sudo() {
    if [ "$(id -u)" = "0" ]; then "$@"; return $?; fi
    if [ "${NCZ_SUDO:-1}" = "0" ]; then "$@"; return $?; fi
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        sudo -- "$@"; return $?
    fi
    if ! _ncz_read_sudo_pass; then
        echo "priv.sh: no passwordless sudo and cannot read $NCZ_SUDO_PASS_KEY from $NCZ_SUDO_PASS_FILE" >&2
        echo "priv.sh: grant passwordless sudo for this account, run as root, or provide the master key file" >&2
        return 1
    fi
    # _ncz_read_sudo_pass populates NCZ_SUDO_PASS; feed THAT to sudo -S (a
    # separate local alias was never assigned here -- review caught it).
    # xtrace must stay off across the feed line too (see _ncz_secret_begin).
    _ncz_secret_begin
    printf '%s\n' "$NCZ_SUDO_PASS" | sudo -S -p '' -- "$@"
    local rc=$?
    unset NCZ_SUDO_PASS
    _ncz_secret_end
    return $rc
}

# Run a whole command STRING as root (for callers that build a shell line).
ncz_sudo_bash() {
    local line="$1"; shift
    # Same hand-back as ncz_container_run(): this helper runs the command as root
    # and its output lands in the clone and the run dir.  The trap must be
    # installed in the CALLER's shell so it fires at the END OF THE STAGE (the
    # stage body runs in a subshell), not at build exit -- otherwise the
    # per-stage ownership post-check sees the root-owned files and fails the
    # build after all the work (measured cycle 502: the layers stage left
    # 134,821 root-owned paths and aborted itself).
    if [ -n "${NCZ_CHOWN_BACK_PATHS:-}" ]; then
        local -a _cbp=()
        IFS=':' read -r -a _cbp <<< "$NCZ_CHOWN_BACK_PATHS"
        [ "${#_cbp[@]}" -gt 0 ] && ncz_trap_chown_back "${_cbp[@]}"
    fi
    ncz_sudo bash -c "$line" "$@"
}

# ---------------------------------------------------------------------------
# Hand privileged build artifacts back to the invoking (non-root) user.
#
# WHY (2026-10-11 "fix open items").  The KVM install gate and the
# provenance gate run through ncz_sudo (as root).  Everything they write under
# the run dir -- kvm-gate/ui-check/, kvm-gate/target-logs/, prov-index/ -- is
# then owned by root, so the build user cannot `rm -rf` a finished run dir
# (36G stranded on a build host; same class as the arm64 .kdebs-tmp stray logs).
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
    local target; target="$(ncz_chown_target)" || return 0
    [ -n "$target" ] || return 0
    local d
    for d in "$@"; do
        [ -e "$d" ] || continue
        if [ "$(id -u)" = "0" ] || [ "${NCZ_CHOWN_BACK_FORCE:-0}" = "1" ]; then
            chown -R "$target" "$d" 2>/dev/null || true
        else
            # ...and only pay for the privileged walk when the tree really holds
            # root-owned entries.  This trap fires once per stage, so a blind
            # sudo chown -R over a whole clone would cost seconds every time.
            # The PROBE must be privileged as well: an unprivileged find cannot
            # descend into a directory the container made root-only, so it would
            # report "nothing to chown" exactly in the case that matters (review,
            # cycle 501).
            ncz_sudo find "$d" -user root -print -quit 2>/dev/null | grep -q . || continue
            # The EXIT trap runs in the INVOKING user's shell, not in the root
            # container.  This branch used to not exist -- a non-root caller
            # returned early, so the host-side trap silently did nothing and every
            # container stage left its output uid 0 (measured: 1730 paths under
            # build/forky-mirror, cycle 500, which then failed the stage's own
            # post-check).  ncz_sudo handles passwordless sudo and the master key;
            # cleanup never fails the caller and never reads a gate verdict.
            ncz_sudo chown -R "$target" "$d" >/dev/null 2>&1 || true
        fi
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
    # (review 2026-10-11).  `trap -p EXIT` prints: trap -- 'CMD' EXIT
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
