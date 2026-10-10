#!/bin/bash
# attest.sh -- emit an in-toto/SLSA-style provenance statement for a built
# image (or payload deb), plus an optional signature via an OPERATOR-HELD key.
#
#   build/attest.sh --subject PATH --arch amd64|arm64 [--run-dir DIR] \
#       [--inputs-lock FILE] [--env-pin FILE] [--gates kvm=PASS,provenance=PASS] \
#       [--builder-id ID] [--out FILE] \
#       [--sign minisign|cosign --key PATH]      # operator key only; never created here
#
# SIGNING KEY CUSTODY (OPERATOR DECISION D7): agents NEVER create, hold, or use
# release signing keys.  This script shells out to `minisign`/`cosign` with a
# key path the operator supplies; without --key the statement is emitted
# UNSIGNED and is still verifiable by its own sha256 (recompute and compare).
#
# The signed statement satisfies the plan's B.6 shape:
#   subject        image sha256 (+ each layer sha256)
#   predicateType  https://slsa.dev/provenance/v1
#   predicate      buildType, builder{id,cpu,kernel,container_digest},
#                  invocation{configSource,parameters,pins},
#                  materials{inputs.lock,env.pin,debs}, gates, byproducts
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

SUBJECT=""; ARCH=""; RUN_DIR=""; INPUTS_LOCK=""; ENV_PIN="$ROOT/manifests/env.pin"
GATES=""; BUILDER_ID=""; OUT=""; SIGN=""; KEY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --subject) SUBJECT="${2:?}"; shift 2 ;;
        --arch) ARCH="${2:?}"; shift 2 ;;
        --run-dir) RUN_DIR="${2:?}"; shift 2 ;;
        --inputs-lock) INPUTS_LOCK="${2:?}"; shift 2 ;;
        --env-pin) ENV_PIN="${2:?}"; shift 2 ;;
        --gates) GATES="${2:?}"; shift 2 ;;
        --builder-id) BUILDER_ID="${2:?}"; shift 2 ;;
        --out) OUT="${2:?}"; shift 2 ;;
        --sign) SIGN="${2:?}"; shift 2 ;;
        --key) KEY="${2:?}"; shift 2 ;;
        -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
        *) echo "attest: unknown argument: $1" >&2; exit 2 ;;
    esac
done
case "$ARCH" in amd64|arm64) ;; *) echo "attest: --arch amd64|arm64 required" >&2; exit 2 ;; esac
[ -n "$SUBJECT" ] || { echo "attest: --subject PATH required" >&2; exit 2; }
[ -e "$SUBJECT" ] || { echo "attest: subject not found: $SUBJECT" >&2; exit 2; }
if [ -z "$RUN_DIR" ]; then RUN_DIR="$(dirname "$SUBJECT")"; fi
[ -s "$INPUTS_LOCK" ] || INPUTS_LOCK="$RUN_DIR/inputs.lock"
[ -n "$OUT" ] || OUT="$SUBJECT.attestation.json"
[ -n "$BUILDER_ID" ] || BUILDER_ID="$(hostname -s)"

BUILDERS="$ROOT/build/config/builders.tsv"
sha256f() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
container_digest() {
    local eng; eng="$(command -v podman || command -v docker || true)"; [ -n "$eng" ] || { echo ""; return; }
    "$eng" image inspect --format '{{.Digest}}' "${NCZ_IMAGEBUILD_TAG:-localhost/ncz-imagebuild:trixie}" 2>/dev/null
}
# builder row -> cpu
build_cpu() { awk -F'\t' -v id="$1" '$1==id{print $4}' "$BUILDERS" 2>/dev/null | head -1; }
build_container() { awk -F'\t' -v id="$1" '$1==id{print $5}' "$BUILDERS" 2>/dev/null | head -1; }

GIT_FULL="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo "")"
GIT_SHA="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo "")"
BASE_DIGEST="$(sha256f "$ROOT/manifests/base.pin")"
DET_DIGEST="$(sha256f "$ROOT/manifests/determinism.pin")"
ENV_DIGEST="$(sha256f "$ENV_PIN")"
LOCK_DIGEST="$(sha256f "$INPUTS_LOCK")"
LOCKSHA="$( [ -s "$INPUTS_LOCK" ] && python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("inputs_lock_digest",""))' "$INPUTS_LOCK" 2>/dev/null || echo "")"

# subjects: the artifact + sibling layers/*.squashfs if present
SUBJ_JSON="$(python3 - "$SUBJECT" <<'PY'
import hashlib, json, os, sys
p = sys.argv[1]
subs = []
if os.path.isfile(p):
    h = hashlib.sha256(open(p, "rb").read()).hexdigest()
    subs.append({"name": os.path.basename(p), "digest": {"sha256": h}})
    d = os.path.dirname(os.path.abspath(p))
    for f in sorted(os.listdir(d) if os.path.isdir(d) else []):
        if f.endswith(".squashfs"):
            q = os.path.join(d, f)
            subs.append({"name": f, "digest": {"sha256": hashlib.sha256(open(q, "rb").read()).hexdigest()}})
print(json.dumps(subs, indent=2))
PY
)"

# gates "kvm=PASS,provenance=PASS" -> {"kvm":"PASS",...}
if [ -n "$GATES" ]; then
    GATES_JSON="$(python3 -c 'import json,sys; d={}; [d.__setitem__(*kv.split("=",1)) for kv in sys.argv[1].replace(","," ").split() if "=" in kv]; print(json.dumps(d))' "$GATES" 2>/dev/null || echo '{}')"
else
    GATES_JSON='{}'
fi

# second-builder claim (D6): arm64 has one builder until cixmini is ready.
SECOND="null"
case "$ARCH" in
    arm64) SECOND='"pending(cixmini)"' ;;
    amd64) SECOND='"hydra|proteus"' ;;
esac

CPU="$(build_cpu "$BUILDER_ID")"; [ -n "$CPU" ] || CPU="$(uname -m)"
CONT="$(build_container "$BUILDER_ID")"; [ -n "$CONT" ] || CONT="${NCZ_IMAGEBUILD_TAG:-localhost/ncz-imagebuild:trixie}"
CONT_DIGEST="$(container_digest)"
KERNEL="$(uname -r)"
CPU_MODEL="$( { [ -r /proc/cpuinfo ] && sed -n 's/^model name.*: //p' /proc/cpuinfo | head -1; } || uname -m)"
STARTED="$( [ -s "$RUN_DIR/run-metadata.json" ] && python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("build_started",""))' "$RUN_DIR/run-metadata.json" 2>/dev/null || echo "" )"
FINISHED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

python3 - "$OUT" "$SUBJ_JSON" "$GATES_JSON" "$GIT_FULL" "$GIT_SHA" "$BUILDER_ID" "$ARCH" \
        "$CPU" "$CPU_MODEL" "$KERNEL" "$CONT" "$CONT_DIGEST" "$BASE_DIGEST" "$DET_DIGEST" \
        "$ENV_DIGEST" "$LOCK_DIGEST" "$LOCKSHA" "$INPUTS_LOCK" "$ENV_PIN" "$SECOND" "$STARTED" "$FINISHED" <<'PY'
import json, os, sys
(OUT, subj, gates, git_full, git_sha, builder_id, arch, cpu, cpu_model,
 kernel, cont, cont_digest, base_d, det_d, env_d, lock_d, lock_sha, lock_path,
 env_path, second, started, finished) = sys.argv[1:]
st = {
  "_type": "https://in-toto.io/Statement/v1",
  "subject": json.loads(subj),
  "predicateType": "https://slsa.dev/provenance/v1",
  "predicate": {
    "buildType": "https://ncz-os/buildtypes/image/v1",
    "builder": {
        "id": builder_id, "arch": arch,
        "cpu": cpu, "cpu_model": cpu_model, "kernel": kernel,
        "container": cont, "container_digest": cont_digest,
    },
    "second_builder": json.loads(second),
    "invocation": {
      "configSource": {"uri": "git+ssh://argonas/mnt/datapool/git/cix-installer.git",
                       "digest": {"sha1": git_full}, "short": git_sha},
      "parameters": {"arch": arch, "pins": {"base": base_d, "determinism": det_d, "env": env_d}},
      "inputs_lock": {"path": os.path.basename(lock_path), "file_sha256": lock_d,
                      "inputs_lock_digest": lock_sha},
      "env_pin": os.path.basename(env_path),
    },
    "materials": [],
    "metadata": {"buildStartedOn": started, "buildFinishedOn": finished,
                 "completeness": {"parameters": True, "environment": True, "materials": False}},
    "gates": json.loads(gates),
    "byproducts": [{"name": "inputs.lock"}, {"name": "env.pin"}],
  },
}
with open(OUT, "w") as fh:
    json.dump(st, fh, indent=2, sort_keys=True); fh.write("\n")
print("attest: wrote %s" % OUT)
PY
STATEMENT_SHA="$(sha256f "$OUT")"
printf '%s  %s\n' "$STATEMENT_SHA" "$(basename "$OUT")" > "$OUT.sha256"
echo "attest: statement sha256=$STATEMENT_SHA (unsigned, verifiable by digest)"

if [ -n "$SIGN" ]; then
    case "$SIGN" in
        minisign)
            command -v minisign >/dev/null || { echo "attest: minisign not installed" >&2; exit 3; }
            [ -n "$KEY" ] || { echo "attest: --sign minisign requires --key <secret key path> (operator-held)" >&2; exit 3; }
            minisign -Sm "$OUT" -s "$KEY" && echo "attest: signed with minisign ($KEY)" ;;
        cosign)
            command -v cosign >/dev/null || { echo "attest: cosign not installed" >&2; exit 3; }
            [ -n "$KEY" ] || { echo "attest: --sign cosign requires --key <key> (operator-held)" >&2; exit 3; }
            cosign sign-blob --yes --key "$KEY" --output-signature "$OUT.sig" "$OUT" \
                && echo "attest: signed with cosign ($KEY)" ;;
        *) echo "attest: unknown --sign '$SIGN' (minisign|cosign)" >&2; exit 2 ;;
    esac
fi
echo "attest: done"
