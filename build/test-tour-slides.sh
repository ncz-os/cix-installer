#!/bin/bash
# test-tour-slides.sh -- parse every NCZ-OS tour slide this repo ships and prove
# it is well formed against the singularity-tour app's own rules.
#
# The tour (desktop id dev.sinty.tour) is an upstream app; NCZ-OS adds slides as
# plain data files, so nothing here is compiled or type-checked by a build. This
# test is the type check for that data. It runs offline, needs only grep/sed/awk,
# and is wired into `make parity`.
#
# Rules enforced (from upstream singularity-tour @ 5dfe27a, src/slides.vala /
# src/scene.vala, pinned in assets/singularity/upstream-pins.tsv):
#   * every file is [Slide] with an integer Order, a non-empty Title, a
#     non-empty Body and a Scene;
#   * Scene is one of the ten built-in scene kinds the app renders:
#       welcome top-bar launcher dock windows workspaces store settings help done
#     (an unknown Scene still loads, but only the `default` branch renders it, so
#      a typo silently loses the illustration: treat it as a failure here);
#   * Order is unique across the NCZ slides AND disjoint from the ten upstream
#     Orders (10 20 30 40 50 60 70 80 90 990 -- the last is 99-done.slide, whose
#     filename prefix is 99 but whose Order is 990);
#   * Title fits the tour's title row (<= 30 characters);
#   * the {os} token is the only brace expression allowed in Title/Body;
#   * Action and ActionLabel are both present or both absent, and Action is one
#     of the prefixes the tour's run_action() understands:
#       app:  settings:  help:  man:  http(s)://
#   * the installed-target hook (post-install/51-ncz-tour-slides.sh) installs
#     exactly the slides present in the asset directory.
#
# Usage: bash build/test-tour-slides.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SLIDE_DIR="${NCZ_TOUR_SLIDE_DIR:-$ROOT/assets/branding/tour-slides}"
HOOK="$ROOT/post-install/51-ncz-tour-slides.sh"

BUILTIN_SCENES=" welcome top-bar launcher dock windows workspaces store settings help done "
# Upstream deck Orders (data/slides/*.slide at the pinned commit).
UPSTREAM_ORDERS="10 20 30 40 50 60 70 80 90 990 "
# The four slides this repo adds ("<order> <basename id>").
EXPECTED="55-ncz-wallpapers 56-ncz-online-wallpapers 65-ncz-screensavers 75-ncz-lock"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1" >&2; }

[ -d "$SLIDE_DIR" ] || { bad "slide dir missing: $SLIDE_DIR"; echo "1..0"; exit 1; }

shopt -s nullglob
files=( "$SLIDE_DIR"/*.slide )
shopt -u nullglob
[ "${#files[@]}" -gt 0 ] || { bad "no *.slide files under $SLIDE_DIR"; exit 1; }

# key <file> <Key> : print the first value of Key in the [Slide] group.
# Whitespace around '=' and around the value is ignored, and a trailing CR is
# dropped, matching GLib KeyFile semantics (the app reads these with
# g_key_file_get_string / get_locale_string).
key() {
    awk -v want="$2" '
        /^\[/ { grp = $0; next }
        grp == "[Slide]" {
            line = $0
            sub(/\r$/, "", line)
            eq = index(line, "=")
            if (eq == 0) next
            k = substr(line, 1, eq - 1); gsub(/^[ \t]+|[ \t]+$/, "", k)
            if (k == want) { v = substr(line, eq + 1); gsub(/^[ \t]+|[ \t]+$/, "", v); print v; exit }
        }' "$1"
}

orders=""
seen_ids=""
for f in "${files[@]}"; do
    base="$(basename "$f" .slide)"

    if ! grep -q '^\[Slide\]' "$f"; then bad "$base: missing [Slide] group"; continue; fi

    order="$(key "$f" Order)"
    title="$(key "$f" Title)"
    body="$(key "$f" Body)"
    scene="$(key "$f" Scene)"
    action="$(key "$f" Action)"
    alabel="$(key "$f" ActionLabel)"

    case "$order" in
        ''|*[!0-9]*) bad "$base: Order is missing or not an integer ('$order')" ;;
    esac

    [ -n "$title" ] || bad "$base: Title is empty (the app refuses a slide without a Title)"
    if [ -n "$title" ] && [ "${#title}" -gt 30 ]; then
        bad "$base: Title is ${#title} chars (limit 30): '$title'"
    fi
    [ -n "$body" ] || bad "$base: Body is empty"
    [ -n "$scene" ] || bad "$base: Scene is empty"

    case "$BUILTIN_SCENES" in
        *" $scene "*) ;;
        *) bad "$base: Scene '$scene' is not one of the ten built-in scenes" ;;
    esac

    # {os} may appear; no other brace expression.
    stripped="$(printf '%s\n%s' "$title" "$body" | sed 's/{os}//g')"
    case "$stripped" in
        *'{'*|*'}'*) bad "$base: Title/Body contains a brace expression other than {os}" ;;
    esac

    # Action pairing + prefix.
    if [ -n "$action" ] && [ -z "$alabel" ]; then bad "$base: Action set but ActionLabel missing (the app clears both)"; fi
    if [ -z "$action" ] && [ -n "$alabel" ]; then bad "$base: ActionLabel set but Action missing (the app clears both)"; fi
    if [ -n "$action" ]; then
        case "$action" in
            app:*|settings:*|help:*|man:*|http://*|https://*) ;;
            *) bad "$base: Action '$action' has no prefix run_action() understands" ;;
        esac
    fi

    # Order uniqueness (NCZ set) + disjoint from upstream.
    case " $orders " in *" $order "*) bad "$base: duplicate Order $order within the NCZ slides" ;; esac
    case "$UPSTREAM_ORDERS" in *" $order "*) bad "$base: Order $order collides with an upstream slide" ;; esac
    orders="$orders $order"

    case " $seen_ids " in *" $base "*) bad "$base: duplicate slide id" ;; esac
    seen_ids="$seen_ids $base"
done

# The expected set (and the hook install list) must match what is on disk.
disk_ids="$(printf '%s\n' "${files[@]}" | xargs -n1 basename | sed 's/\.slide$//' | LC_ALL=C sort | tr '\n' ' ')"
want_ids="$(printf '%s\n' $EXPECTED | LC_ALL=C sort | tr '\n' ' ')"
if [ "$disk_ids" = "$want_ids" ]; then ok "shipped slide set == expected ($want_ids)"; else bad "shipped slide set is '$disk_ids', expected '$want_ids'"; fi

if [ -f "$HOOK" ]; then
    hook_ids="$(sed -n 's/^ *for s in \(.*\); do$/\1/p' "$HOOK" | tr -s ' ' '\n' | grep -v '^$' | LC_ALL=C sort | tr '\n' ' ')"
    if [ "$hook_ids" = "$want_ids" ]; then ok "hook install list matches the asset set"; else bad "hook install list '$hook_ids' != asset set '$want_ids'"; fi
else
    bad "hook missing: $HOOK"
fi

echo "$((PASS + FAIL)) checks, $PASS ok, $FAIL failed"
[ "$FAIL" -eq 0 ]
