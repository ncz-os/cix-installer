#!/usr/bin/env bash
# check-hook-registration.sh -- fail closed when a post-install hook is not
# registered in exactly one execution list.
#
# WHY (UX inventory S4-4): run-all.sh dispatches optional hooks through
# MACHINE_HOOKS_RE, an 81-entry hand-maintained regex. A newly added hook that
# nobody registers is detected by run-all.sh's orphan warning, but that warning
# only PRINTS - it does not fail. So the hook silently never runs and the
# install still reports success. In an unattended/headless install nobody reads
# the warning.
#
# This test moves that failure to CI, where it is cheap and loud, and leaves the
# install-time behaviour as a warning (failing at install would brick a
# headless install, which is worse).
#
# It is a TEST, not a dispatch change: no hook ordering or selection is touched.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2
RUN_ALL="post-install/run-all.sh"
HOOK_DIR="post-install"

[ -f "$RUN_ALL" ] || { echo "check-hook-registration: missing $RUN_ALL" >&2; exit 2; }

python3 - "$RUN_ALL" "$HOOK_DIR" <<'PY'
import glob, os, re, sys

run_all, hook_dir = sys.argv[1], sys.argv[2]
src = open(run_all).read()


def quoted(name):
    """Entries of a shell double-quoted list, e.g. MACHINE_HOOKS_RE="a|b|c"."""
    m = re.search(r'%s="([^"]*)"' % re.escape(name), src, re.S)
    if not m:
        return None
    return {x.strip() for x in m.group(1).split("|") if x.strip()}


def unquoted(name):
    """Entries of a shell command-substitution list, e.g. FOO="$(printf ...)".
    Falls back to every NN-name.sh token appearing in the variable's body."""
    m = re.search(r'%s="\$\((.*?)\)"' % re.escape(name), src, re.S)
    if not m:
        return None
    return {mm.group(1) for mm in re.finditer(r'([0-9]{2}-[a-z0-9_-]+)\.sh', m.group(1))}


def bare(names):
    """run-all.sh writes these as regex fragments like "^(a|b|c)". Strip the
    anchors so entries compare as plain hook names."""
    out = set()
    for n in names:
        n = n.strip()
        if n.startswith("^("):
            n = n[2:]
        if n.endswith(")$"):
            n = n[:-2]
        if n:
            out.add(n)
    return out

machine = bare(quoted("MACHINE_HOOKS_RE") or set())
required = bare(unquoted("REQUIRED_HOOKS") or set())

on_disk = {os.path.basename(f)[:-3]
           for f in glob.glob(os.path.join(hook_dir, "[0-9][0-9]-*.sh"))}

# A hook may legitimately be invoked by name somewhere other than these two
# lists (e.g. called explicitly). Collect those so we do not flag them.
# A hook may be invoked by name somewhere other than these two lists, or it may
# be selected per-architecture from an external $HOOKS_LIST (run-all.sh builds
# _PLAT_SKIP_RE from it). Either way it is reachable, so it is NOT an orphan.
referenced_elsewhere = set(re.findall(r'([0-9]{2}-[a-z0-9_-]+)\.sh', src))

# run-all.sh strips the leading "^(...)$" anchors; do the same so entries are
# compared as bare hook names.

unregistered = sorted(
    h for h in on_disk
    if h not in machine and h not in required and h not in referenced_elsewhere
)
in_both = sorted((machine & required) & on_disk)

if unregistered:
    print("check-hook-registration: FAIL - these hooks exist but are in NO "
          "execution list and are never referenced. They would silently never "
          "run:")
    for h in unregistered:
        print("    ORPHAN %s" % h)
    print("  Fix: register each in MACHINE_HOOKS_RE (optional/conditional) or "
          "REQUIRED_HOOKS (always), then re-run.")
    sys.exit(1)

if in_both:
    print("check-hook-registration: FAIL - these hooks are in BOTH execution "
          "lists; that is ambiguous and can double-run:")
    for h in in_both:
        print("    DUPLICATE %s" % h)
    sys.exit(1)

print("check-hook-registration: OK - %d hooks on disk, all registered "
      "(%d MACHINE_HOOKS_RE, %d REQUIRED)."
      % (len(on_disk), len(machine), len(required)))
PY