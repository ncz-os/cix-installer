#!/bin/bash
# The base.squashfs reuse check must notice a changed asset (2026-09-29: stale audio daemon + missing ncz-gpu-hw-present).
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SRC="$HERE/build-squashfs-layers.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAILS=0
ok() { PASS=$((PASS+1)); echo "ok   $1"; }; no() { FAILS=$((FAILS+1)); echo "FAIL $1"; }
awk '/^BASE_STAMP_REL=/{print} /^base_assets_stamp\(\) \{/{f=1} f{print} f&&/^}$/{f=0}' "$SRC" > "$T/fn.sh"
grep -q base_assets_stamp "$T/fn.sh" && ok "stamp function extracted from build-squashfs-layers.sh" || no "stamp function missing"
R="$T/root"; mkdir -p "$R/assets/gpu" "$R/assets/audio" "$R/manifests" "$R/assets/cix-debs"
echo a > "$R/assets/gpu/ncz-gpu-status"; echo b > "$R/assets/audio/x.py"; echo c > "$R/manifests/base.pkgs"; echo r > "$R/release.conf"; echo big > "$R/assets/cix-debs/a.deb"
stamp() { ROOT="$R" bash -c ". '$T/fn.sh'; base_assets_stamp"; }
s0="$(stamp)"; [ -n "$s0" ] && [ "$s0" = "$(stamp)" ] && ok "stamp is stable for unchanged inputs" || no "stamp unstable/empty"
echo a2 > "$R/assets/gpu/ncz-gpu-status"; s1="$(stamp)"; [ "$s1" != "$s0" ] && ok "editing assets/gpu changes the stamp" || no "gpu edit not noticed"
echo n > "$R/assets/gpu/ncz-gpu-hw-present"; s2="$(stamp)"; [ "$s2" != "$s1" ] && ok "a NEW file in assets/gpu changes the stamp" || no "new file not noticed"
echo b2 > "$R/assets/audio/x.py"; [ "$(stamp)" != "$s2" ] && ok "editing assets/audio changes the stamp" || no "audio edit not noticed"
s3="$(stamp)"; echo bigger > "$R/assets/cix-debs/a.deb"; [ "$(stamp)" = "$s3" ] && ok "large payload dirs (cix-debs) are not hashed" || no "cix-debs should not affect the stamp"
echo c2 > "$R/manifests/base.pkgs"; [ "$(stamp)" != "$s3" ] && ok "editing a manifest changes the stamp" || no "manifest edit not noticed"
grep -q 'base_assets_stamp | sudo tee' "$SRC" && ok "build_base writes the stamp into the layer" || no "build_base does not write the stamp"
grep -q '_have_stamp="$(base_stamp_in_layer' "$SRC" && ok "the reuse check compares the layer's stamp" || no "reuse check does not compare"
echo "base stamp tests: $PASS passed, $FAILS failed"; [ "$FAILS" = 0 ]
