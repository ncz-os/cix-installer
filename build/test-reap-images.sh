#!/bin/bash
# fixture tests for build/reap-images.sh
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
R="$HERE/reap-images.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAILS=0
ok() { PASS=$((PASS+1)); echo "ok   $1"; }; no() { FAILS=$((FAILS+1)); echo "FAIL $1"; }
mkimg() {   # dir arch id age-in-hours [gated] [validated]
    local f="$1/ncz-os-$2-20260929-$3.img"; mkdir -p "$1"; head -c 64 /dev/urandom > "$f"; touch -d "$4 hours ago" "$f"
    echo "$5" | grep -q gated && echo x > "$f.gated"; echo "$6" | grep -q validated && echo x > "$f.validated"
    echo receipt > "$f.receipt.json"; echo sum > "$f.sha256"
}
fresh() {
    rm -rf "$T/host" "$T/argo" "$T/rem" "$T/wk"; mkdir -p "$T/host" "$T/argo" "$T/rem" "$T/wk"
    mkimg "$T/host" arm64 aaaa0001 50 gated; mkimg "$T/argo" arm64 aaaa0001 50 gated     # old gated, two copies
    mkimg "$T/host" arm64 aaaa0002 40 ""                                                  # old, never gated
    mkimg "$T/host" arm64 aaaa0003 30 gated; mkimg "$T/argo" arm64 aaaa0003 30 gated     # newest gated, archived
    mkimg "$T/host" arm64 aaaa0004 5 ""                                                   # newer, ungated (in flight)
    mkimg "$T/rem"  arm64 aaaa0001 50 gated                                               # third copy on a "remote" host
    mkimg "$T/host" amd64 bbbb0001 60 gated; mkimg "$T/host" amd64 bbbb0002 10 gated     # other arch
    mkdir -p "$T/wk/kvm-install-arm64-aaaa0001" "$T/wk/kvm-install-arm64-aaaa0003" "$T/wk/kvm-install-amd64-bbbb0001"
}
FAKESSH="$T/fakessh"; printf '#!/bin/bash\nshift\nexec bash -c "$1"\n' > "$FAKESSH"; chmod +x "$FAKESSH"
run() { SSH="$FAKESSH" bash "$R" --arch arm64 --archive "$T/argo" --dir "$T/host" --remote "fake:$T/rem" --workdir "$T/wk/kvm-install-*" "$@"; }
n_imgs() { ls "$1"/ncz-os-"$2"-*.img 2>/dev/null | wc -l | tr -d ' '; }

fresh; run > "$T/out" 2>&1
[ -f "$T/host/ncz-os-arm64-20260929-aaaa0001.img" ] && [ -f "$T/argo/ncz-os-arm64-20260929-aaaa0001.img" ] && [ -f "$T/rem/ncz-os-arm64-20260929-aaaa0001.img" ] && ok "dry run (default) deletes nothing" || no "dry run deleted something"
grep -q "would delete .*aaaa0001" "$T/out" && ok "dry run lists the superseded image" || no "dry run did not list it"
[ ! -e "$T/argo/reap.log" ] && ok "dry run writes no log" || no "dry run wrote a log"
run --apply > "$T/out" 2>&1
[ ! -e "$T/host/ncz-os-arm64-20260929-aaaa0001.img" ] && [ ! -e "$T/argo/ncz-os-arm64-20260929-aaaa0001.img" ] && [ ! -e "$T/rem/ncz-os-arm64-20260929-aaaa0001.img" ] && ok "--apply reaps EVERY copy (host, archive, remote) of an old gated image" || no "old gated image not fully reaped"
[ ! -e "$T/host/ncz-os-arm64-20260929-aaaa0001.img.receipt.json" ] && [ ! -e "$T/host/ncz-os-arm64-20260929-aaaa0001.img.gated" ] && ok "sidecars are reaped with the image" || no "sidecars left behind"
[ -f "$T/host/ncz-os-arm64-20260929-aaaa0003.img" ] && [ -f "$T/argo/ncz-os-arm64-20260929-aaaa0003.img" ] && ok "the newest gated image is kept everywhere" || no "newest gated image was deleted"
[ -f "$T/host/ncz-os-arm64-20260929-aaaa0004.img" ] && ok "an image newer than the newest gated one is kept" || no "in-flight image was deleted"
[ -f "$T/host/ncz-os-arm64-20260929-aaaa0002.img" ] && ok "an old image with no .gated marker is kept unless named" || no "ungated image was deleted"
[ "$(n_imgs "$T/host" amd64)" = 2 ] && ok "the other architecture is never touched" || no "amd64 images were touched"
[ ! -d "$T/wk/kvm-install-arm64-aaaa0001" ] && [ -d "$T/wk/kvm-install-arm64-aaaa0003" ] && [ -d "$T/wk/kvm-install-amd64-bbbb0001" ] && ok "workdirs: reaped id removed, kept id and other arch untouched" || no "workdir handling wrong"
grep -Eq "reaped .*aaaa0001.* sha256=[0-9a-f]{64}" "$T/argo/reap.log" && ok "each deletion is logged with its sha256" || no "reap.log missing sha256 lines"

fresh; run --apply --supersede ncz-os-arm64-20260929-aaaa0002.img > "$T/out" 2>&1
[ ! -e "$T/host/ncz-os-arm64-20260929-aaaa0002.img" ] && ok "--supersede reaps a pre-marker image the operator ruled out" || no "--supersede ignored"

fresh; echo x > "$T/host/ncz-os-arm64-20260929-aaaa0001.img.validated"
run --apply > "$T/out" 2>&1
[ -f "$T/host/ncz-os-arm64-20260929-aaaa0001.img" ] && ok "the newest operator-validated image is kept as the fallback" || no "validated image reaped"

fresh; rm -f "$T/argo/ncz-os-arm64-20260929-aaaa0003.img"
run --apply > "$T/out" 2>&1; rc=$?
[ $rc != 0 ] && [ -f "$T/host/ncz-os-arm64-20260929-aaaa0001.img" ] && ok "newest gated image not in the archive: refuses, deletes nothing" || no "reaped although the newest image is not archived"

fresh; rm -f "$T"/host/*.gated "$T"/argo/*.gated "$T"/rem/*.gated
run --apply > "$T/out" 2>&1; rc=$?
[ $rc != 0 ] && [ "$(n_imgs "$T/host" arm64)" = 4 ] && ok "no gated image at all: refuses" || no "reaped with nothing gated"

fresh; rm -f "$T/host/ncz-os-arm64-20260929-aaaa0003.img.gated" "$T/argo/ncz-os-arm64-20260929-aaaa0003.img.gated"
bash "$R" --mark-gated "$T/argo/ncz-os-arm64-20260929-aaaa0003.img" --note test > /dev/null 2>&1
grep -q '^sha256=[0-9a-f]\{64\}' "$T/argo/ncz-os-arm64-20260929-aaaa0003.img.gated" && ok "--mark-gated records name, sha256 and time" || no "--mark-gated wrote no sha256"
echo "reap-images tests: $PASS passed, $FAILS failed"; [ "$FAILS" = 0 ]
