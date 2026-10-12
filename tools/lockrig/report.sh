#!/usr/bin/env bash
# tools/lockrig/report.sh -- consolidate per-host lockrig output into a matrix.
# Writes $OUT/matrix.md, $OUT/matrix.json and one contact sheet per host.
# Usage: report.sh --out DIR --hosts a,b,c [--repo ROOT]
set -u
OUT=""; HOSTS=""; REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:-}"; shift 2;;
    --hosts) HOSTS="${2:-}"; shift 2;;
    --repo) REPO="${2:-}"; shift 2;;
    *) shift;;
  esac
done
[ -n "$OUT" ] || { echo "report: --out required" >&2; exit 2; }
IFS=',' read -r -a SEL <<< "$HOSTS"

ORDER="PREFLIGHT LEASE ATTENDED_GATE T1 T2 T3 T3b T4 T5 T6 T7 T8 T9 T10 T11 T12 T13 T14 T15 TRESTORE TH RUN"

status_of() { # $1 hostdir $2 case
  awk -F'\t' -v c="$2" '$1==c{print $2; exit}' "$1/cases.tsv" 2>/dev/null
}
detail_of() {
  awk -F'\t' -v c="$2" '$1==c{ $1=""; $2=""; sub(/^\t\t/,""); print; exit}' "$1/cases.tsv" 2>/dev/null
}
mode_of() { sed -n 's/.*"mode":"\([^"]*\)".*/\1/p' "$1/result.json" 2>/dev/null | head -1; }

# collect all cases seen
ALL=""
for name in "${SEL[@]}"; do
  d="$OUT/$name"; [ -d "$d" ] || continue
  for c in $(cut -f1 "$d/cases.tsv" 2>/dev/null); do echo "$c"; done
done | awk '!seen[$0]++' > "$OUT/.cases"
# ordered union
ORDERED=""
for c in $ORDER; do grep -qx "$c" "$OUT/.cases" && ORDERED="$ORDERED $c"; done
while read -r c; do [ -z "$c" ] && continue; echo " $ORDERED " | grep -q " $c " || ORDERED="$ORDERED $c"; done < "$OUT/.cases"

# totals
tp=0; tf=0; ts=0
{
  echo "# lockrig matrix — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "Owner: \`${LOCKRIG_OWNER:-?}\`  Output: \`$OUT\`"
  echo
  printf '| case |'
  for name in "${SEL[@]}"; do printf ' %s |' "$name"; done
  echo
  printf '|---|'
  for name in "${SEL[@]}"; do printf '%s|' "$(printf -- '-%.0s' $(seq 1 ${#name}))"; done
  echo
  for c in $ORDERED; do
    printf '| %s |' "$c"
    for name in "${SEL[@]}"; do
      s="$(status_of "$OUT/$name" "$c")"; [ -z "$s" ] && s="—"
      case "$s" in PASS) printf ' ✅ |';; FAIL) printf ' ❌ |';; SKIP) printf ' ⏭️ |';; *) printf ' %s |' "$s";; esac
      case "$s" in PASS) tp=$((tp+1));; FAIL) tf=$((tf+1));; SKIP) ts=$((ts+1));; esac
    done
    echo
  done
  echo
  echo "Totals across hosts: **PASS $tp / FAIL $tf / SKIP $ts**"
  echo
  echo "## Per-host notes"
  echo
  for name in "${SEL[@]}"; do
    d="$OUT/$name"; [ -d "$d" ] || continue
    echo "### $name (mode=$(mode_of "$d"))"
    if [ -s "$d/cases.tsv" ]; then
      while IFS=$'\t' read -r c s det; do echo "- **$c** $s — $det"; done < "$d/cases.tsv"
    else
      echo "- (no cases captured)"
    fi
    echo
  done
} > "$OUT/matrix.md"

# contact sheets
for name in "${SEL[@]}"; do
  d="$OUT/$name"; [ -d "$d" ] || continue
  imgs=$(ls "$d"/*-card.png "$d"/m*.png "$d"/t*-*.png "$d"/idle*.png 2>/dev/null | head -12)
  [ -z "$imgs" ] && continue
  if command -v magick >/dev/null 2>&1; then
    magick montage $imgs -tile 3x -geometry 400x250+3+3 -background '#222' -label '%f' "$OUT/contact-$name.png" 2>/dev/null \
      && echo "report: wrote $OUT/contact-$name.png"
  fi
done

# JSON
{
  echo "{"
  echo "  \"generated\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
  echo "  \"owner\": \"${LOCKRIG_OWNER:-}\","
  echo "  \"totals\": {\"pass\": $tp, \"fail\": $tf, \"skip\": $ts},"
  echo "  \"hosts\": {"
  first=1
  for name in "${SEL[@]}"; do
    d="$OUT/$name"; [ -d "$d" ] || continue
    [ "$first" = 1 ] || echo ","
    first=0
    printf '    "%s": {"mode":"%s","cases": {' "$name" "$(mode_of "$d")"
    sep=""
    while IFS=$'\t' read -r c s det; do [ -z "$c" ] && continue
      printf '%s"%s":"%s"' "$sep" "$c" "$s"; sep=","
    done < "$d/cases.tsv"
    printf '}}'
  done
  echo
  echo "  }"
  echo "}"
} > "$OUT/matrix.json"

echo "report: $OUT/matrix.md  $OUT/matrix.json  (PASS $tp / FAIL $tf / SKIP $ts)"
