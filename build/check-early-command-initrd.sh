#!/bin/bash
# check-early-command-initrd.sh <unpacked-initrd-root> [preseed.cfg]
#   -- run the REAL d-i preseed loader chain from a netinst initrd against our
#      preseed.cfg and prove the stored preseed/early_command parses.
#
# What runs, in a chroot of a scratch copy of the initrd (nothing in the
# given root is modified), exactly as d-i does at boot:
#   S20templates   debconf-loadtemplate d-i /var/lib/dpkg/info/*.templates
#   S30            debconf-set-selections /preseed.cfg   (preseed-common's
#                  joiner + cdebconf's database, via /usr/lib/cdebconf/debconf)
#   S33 (first half)  db_get preseed/early_command       (what preseed_command
#                  hands to `sh -c`)
# then `/bin/sh -n` on that value with the initrd's own shell (busybox ash),
# and a byte comparison with build/check-early-command-size.sh --print-joined
# so the static mirror of the joiner is proven against the real one.
#
# Needs root (chroot) and a host of the initrd's architecture. Exit codes:
#   0 OK, 1 the stored value does not parse / mirrors differ, 2 usage,
#   77 cannot run here (not root, wrong arch, tools missing) -- callers treat
#   77 as SKIP. NCZ_SCRATCH_DIR (default: alongside the initrd root) holds the
#   scratch copy; it is removed on exit. The copy excludes kernel modules and
#   firmware, so it is ~60 MB, not ~600 MB.
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
IR="${1:-}"; CFG="${2:-$ROOT/preseed/preseed.cfg}"
[ -n "$IR" ] && [ -d "$IR" ] || { echo "usage: $0 <unpacked-initrd-root> [preseed.cfg]" >&2; exit 2; }
[ -r "$CFG" ] || { echo "check-early-command-initrd: cannot read $CFG" >&2; exit 2; }
[ -x "$IR/usr/lib/cdebconf/debconf" ] && [ -f "$IR/usr/bin/debconf-set-selections" ] \
    || { echo "check-early-command-initrd: $IR is not an unpacked d-i initrd (no cdebconf)" >&2; exit 77; }
[ "$(id -u)" = 0 ] || { echo "check-early-command-initrd: needs root for chroot (SKIP)" >&2; exit 77; }
case "$(uname -m):$(file -b "$IR/bin/busybox" 2>/dev/null)" in
    x86_64:*x86-64*|aarch64:*aarch64*|aarch64:*ARM\ aarch64*) ;;
    *) echo "check-early-command-initrd: host $(uname -m) cannot chroot this initrd ($(file -b "$IR/bin/busybox" | cut -c1-60)) (SKIP)" >&2; exit 77 ;;
esac

S="$(mktemp -d "${NCZ_SCRATCH_DIR:-$(dirname "$IR")}/ncz-ec-initrd.XXXXXX")"
trap 'rm -rf "$S"' EXIT
# Scratch copy without the bulk (modules/firmware are irrelevant to cdebconf).
tar -C "$IR" --exclude=./lib/modules --exclude=./usr/lib/modules \
    --exclude=./lib/firmware --exclude=./usr/lib/firmware -cf - . | tar -C "$S" -xf - \
    || { echo "check-early-command-initrd: copy failed" >&2; exit 2; }
mkdir -p "$S/dev" "$S/var/lib/preseed" "$S/var/lib/cdebconf" "$S/tmp"
[ -c "$S/dev/null" ] || mknod "$S/dev/null" c 1 3
cp "$CFG" "$S/preseed.cfg"
cat > "$S/ncz-ec-get.sh" <<'EOF'
#!/bin/sh
# Confmodule client: re-executed by /usr/lib/cdebconf/debconf (confmodule's
# own exec), then asks for the stored value exactly as /bin/preseed_command.
. /usr/share/debconf/confmodule
db_get preseed/early_command
printf '%s\n' "$RET" > /early-command.stored
EOF
chmod 755 "$S/ncz-ec-get.sh"

run() { chroot "$S" /bin/sh -c "export PATH=/usr/bin:/bin:/usr/sbin:/sbin DEBIAN_FRONTEND=none DEBCONF_DEBUG= ; $1"; }
run 'debconf-loadtemplate d-i /var/lib/dpkg/info/*.templates' 2>"$S/s20.err" \
    || { echo "check-early-command-initrd: S20 debconf-loadtemplate failed: $(cat "$S/s20.err")" >&2; exit 2; }
if ! run 'debconf-set-selections /preseed.cfg' 2>"$S/s30.err"; then
    echo "check-early-command-initrd: FAIL: the initrd's debconf-set-selections rejected $CFG:" >&2
    sed 's/^/    /' "$S/s30.err" "$S/var/lib/preseed/log" 2>/dev/null | tail -20 >&2
    exit 1
fi
run '/ncz-ec-get.sh' 2>"$S/get.err" || { echo "check-early-command-initrd: db_get failed: $(cat "$S/get.err")" >&2; exit 2; }
[ -s "$S/early-command.stored" ] || { echo "check-early-command-initrd: FAIL: stored preseed/early_command is empty" >&2; exit 1; }

stored_lines="$(wc -l < "$S/early-command.stored")"
if [ "$stored_lines" != 1 ]; then
    echo "check-early-command-initrd: FAIL: the stored value is $stored_lines lines, not one (a backslash escape was interpreted)" >&2
    exit 1
fi
if ! run '/bin/sh -n /early-command.stored' 2>"$S/sh-n.err"; then
    echo "check-early-command-initrd: FAIL: the stored preseed/early_command does not parse under the initrd's /bin/sh -n:" >&2
    sed 's/^/    /' "$S/sh-n.err" >&2
    echo "check-early-command-initrd:       d-i would run it with sh -c, it would exit 2, and cdebconf 0.283 would abort on the preseed/command_failed dialog (lookup_directive assertion)." >&2
    exit 1
fi
if ! bash "$ROOT/build/check-early-command-size.sh" --print-joined "$CFG" > "$S/early-command.mirror" 2>"$S/mirror.err"; then
    echo "check-early-command-initrd: FAIL: the static joiner refused the file the real loader accepted: $(cat "$S/mirror.err")" >&2
    exit 1
fi
if ! cmp -s "$S/early-command.stored" "$S/early-command.mirror"; then
    echo "check-early-command-initrd: FAIL: the static joiner (check-early-command-size.sh --print-joined) and the initrd's debconf-set-selections stored different values:" >&2
    diff <(fold -w 120 "$S/early-command.stored") <(fold -w 120 "$S/early-command.mirror") | head -20 >&2
    exit 1
fi
echo "check-early-command-initrd: OK ($(wc -c < "$S/early-command.stored") bytes stored by the initrd's loader; parses under its /bin/sh -n; identical to the static joiner)"
