#!/bin/bash
# The plugin (singularity-plugins) looks its helpers up as singularity-wallpaper-ocs
# and singularity-wallpaper-bing in PATH; post-install/45-wallpaper-rotator.sh
# satisfies that with symlinks to the ncz-wallpaper-* helpers. A helper that
# dispatched on argv[0] would behave differently when invoked through the
# symlink, and a symlink would silently shadow or expose a different getopt set.
# Assert the helpers dispatch on argv[1] only: every subcommand the plugin and
# the rotator call must produce identical stdout through either name.
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
A="$HERE/../assets/wallpaper"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
BIN="$T/bin"; mkdir -p "$BIN"
PASS=0; FAILS=0; ok() { PASS=$((PASS+1)); echo "ok   $1"; }; no() { FAILS=$((FAILS+1)); echo "FAIL $1"; }

# Reproduce the installer's staging: install the helper, then symlink the
# singularity-wallpaper-* name at it (exactly as 45-wallpaper-rotator.sh does).
for n in ncz-wallpaper-bing ncz-wallpaper-ocs; do
  [ -x "$A/$n" ] || { no "$n is not executable in assets/wallpaper"; continue; }
  install -m 0755 "$A/$n" "$BIN/$n"
  ln -sf "$n" "$BIN/${n/ncz-/singularity-}"
done

export NCZ_BING_DATA_ROOT="$T/data" NCZ_BING_QUIET=1 \
       XDG_CACHE_HOME="$T/cache" XDG_CONFIG_HOME="$T/cfg" HOME="$T"

# ncz-wallpaper-bing: the subcommands the plugin/rotator call.
for sub in "markets" "market" "list"; do
  a=$(bash "$BIN/ncz-wallpaper-bing" $sub 2>&1)
  b=$(bash "$BIN/singularity-wallpaper-bing" $sub 2>&1)
  [ "$a" = "$b" ] && ok "bing $sub: singularity-wallpaper-bing == ncz-wallpaper-bing" \
                  || no "bing $sub differs via the symlink"
done
# argv[0] must not influence the output at all.
a=$(cd "$T" && bash "$BIN/ncz-wallpaper-bing" markets 2>&1)
b=$(cd / && bash "$BIN/singularity-wallpaper-bing" markets 2>&1)
[ "$a" = "$b" ] && ok "bing markets is independent of argv[0] and cwd" || no "bing markets depends on invocation"

# ncz-wallpaper-ocs: at least the help/usage path must be argv[0]-independent.
if bash "$BIN/ncz-wallpaper-ocs" 2>&1 | grep -qiE 'usage|fetch|index|markets'; then
  a=$(bash "$BIN/ncz-wallpaper-ocs" 2>&1); b=$(bash "$BIN/singularity-wallpaper-ocs" 2>&1)
  [ "$a" = "$b" ] && ok "ocs usage: singularity-wallpaper-ocs == ncz-wallpaper-ocs" \
                  || no "ocs usage differs via the symlink"
else
  ok "ocs has no self-describing usage (nothing to compare)"
fi

# The symlink must resolve to the same inode (a real hard/soft link, not a copy).
for n in ncz-wallpaper-bing ncz-wallpaper-ocs; do
  s="${n/ncz-/singularity-}"
  [ "$(readlink -f "$BIN/$s")" = "$(readlink -f "$BIN/$n")" ] && ok "$s -> $n resolves to one file" \
    || no "$s does not resolve to $n"
done

echo "wallpaper helper-symlink tests: $PASS passed, $FAILS failed"; [ "$FAILS" = 0 ]
