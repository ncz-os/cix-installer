#!/bin/bash
# test-ncz-cli-embedder.sh -- assert the embedder / models pull /
# SQLite-backfill paths in post-install/46-ncz-cli.sh are statically
# intact: model path, sha256, public source, retry contract, offline
# diagnostic, status exposure. Pure source assertions; no live host
# needed.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/post-install/46-ncz-cli.sh"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

[ -f "$HOOK" ] && ok "post-install/46-ncz-cli.sh exists" || bad "post-install/46-ncz-cli.sh missing"

# `ncz models pull` real implementation:
#   - HuggingFace public URL
#   - Pinned sha256 (the same file MNEMOS ships at
#     /opt/mnemos/models/nomic-embed-text-v1.5.Q8_0.gguf)
#   - Idempotency: skip when file is present with the right sha256
#   - 3 retries
#   - Offline diagnostic when all 3 fail
grep -q 'huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF' "$HOOK" \
    && ok "models pull targets HuggingFace nomic-embed-text-v1.5-GGUF" \
    || bad "models pull does NOT target HuggingFace public source"
grep -q "sha256='3e24342164b3d94991ba9692fdc0dd08e3fd7362e0aacc396a9a5c54a544c3b7'" "$HOOK" \
    && ok "models pull pinned sha256 matches MNEMOS image content" \
    || bad "models pull pinned sha256 is missing or has drifted"
grep -q 'attempt in 1 2 3' "$HOOK" \
    && ok "models pull retries 3 times" \
    || bad "models pull does NOT retry 3 times"
grep -q 'sha256sum' "$HOOK" \
    && ok "models pull verifies downloaded sha256" \
    || bad "models pull does NOT verify downloaded sha256"
grep -q 'this system is offline' "$HOOK" \
    && ok "models pull prints offline diagnostic on fetch failure" \
    || bad "models pull does NOT print offline diagnostic"
# Idempotency: skip when file is already present + correct hash.
grep -qE "already present, sha256 matches" "$HOOK" \
    && ok "models pull is idempotent (skip when present+correct hash)" \
    || bad "models pull is NOT idempotent on present+correct"

# MNEMOS install wires the embedder backend/model-path env var so the
# orchestrator can tell which backend is active without reading the
# source. The quadlet env var is the canonical knob.
grep -qE 'MNEMOS_EMBED_MODEL_PATH|/opt/mnemos/models/' "$HOOK" \
    && ok "MNEMOS install references the in-image embedder model path" \
    || bad "MNEMOS install does NOT reference the embedder model path"

# ncz status exposes the embedder state. We assert the sentence labels
# so a regression to a single-line status fails.
grep -q "mnemos service:" "$HOOK" && ok "ncz status surfaces mnemos service line" \
    || bad "ncz status does NOT surface mnemos service line"
grep -q "mnemos embedder:" "$HOOK" && ok "ncz status surfaces mnemos embedder line" \
    || bad "ncz status does NOT surface mnemos embedder line"
grep -q "mnemos model:" "$HOOK" && ok "ncz status surfaces mnemos model line" \
    || bad "ncz status does NOT surface mnemos model line"
grep -q "mnemos health:" "$HOOK" && ok "ncz status surfaces mnemos health line" \
    || bad "ncz status does NOT surface mnemos health line"

# SQLite memory_embeddings backfill at end of ncz_install_mnemos:
#   - idempotent INSERT OR IGNORE
#   - runs via podman exec inside the running container
#   - has a graceful FAIL path (warn + carry on, do not fail install)
grep -q "INSERT OR IGNORE INTO memory_embeddings" "$HOOK" \
    && ok "ncz install mnemos backfills memory_embeddings idempotently" \
    || bad "ncz install mnemos does NOT backfill memory_embeddings"
grep -q "podman exec mnemos python3" "$HOOK" \
    && ok "backfill runs inside the mnemos container" \
    || bad "backfill does NOT run inside the mnemos container"
grep -qE "WARN: SQLite memory_embeddings backfill failed" "$HOOK" \
    && ok "backfill failure is non-fatal (warn + carry on)" \
    || bad "backfill failure is treated as fatal"

# Host-side embedder model pull is called as part of `ncz install mnemos`
# so a single `ncz install mnemos` lands the whole embedder stack.
grep -q "ncz_models_pull" "$HOOK" \
    && grep -q "ncz install mnemos" "$HOOK" \
    && ok "ncz install mnemos triggers ncz_models_pull" \
    || bad "ncz install mnemos does NOT trigger ncz_models_pull"

# Regression: the backfill exit-status variable MUST be pre-initialised.
# The naive form `out="$(...)" || rc=$?` leaves `rc` unset on the SUCCESS
# path, so the following `[ "$rc" = "0" ]` under `set -u` aborts the whole
# install with `line N: rc: unbound variable` AFTER everything succeeded
# (reproduced live 2026-10-13). The fixed form initialises the variable.
grep -q 'local backfill_out backfill_rc=0' "$HOOK" \
    && ok "backfill status var is initialised (no unbound-rc abort on success)" \
    || bad "backfill status var is NOT initialised — install aborts with rc: unbound variable"
grep -q '|| backfill_rc=\$?' "$HOOK" \
    && ok "backfill captures its status into the local var" \
    || bad "backfill does NOT capture status into the local var"
if grep -q '|| rc=\$?' "$HOOK"; then
    bad "backfill still assigns the uninitialised global rc"
else
    ok "no assignment to the uninitialised global rc remains"
fi

# ncz status must report the real embedding width. The .cix NPU graph is the
# same nomic-embed-text-v1.5 model at 768 dims; its 256 is max_tokens, not the
# embedding width, so status must not print dim=256 for .cix.
grep -q '\*.cix)  embed_dim=768' "$HOOK" \
    && ok "status reports 768-dim for the .cix embedder graph" \
    || bad "status maps .cix to the wrong dimension"
if grep -q 'embed_dim=256' "$HOOK"; then
    bad "status still reports a 256-dim embedder (max_tokens != dim)"
else
    ok "status no longer conflates max_tokens with embedding dimension"
fi

# Sky1 NPU embedder is opt-in: the default path reports the CPU embedder and
# does NOT apt-install the (currently non-functional) NPU stack.
grep -q 'NCZ_MNEMOS_NPU' "$HOOK" \
    && ok "ncz install mnemos exposes the NPU opt-in switch" \
    || bad "ncz install mnemos has no NPU opt-in switch"
grep -q 'cix-npu embedder is disabled' "$HOOK" \
    && ok "default path states the cix-npu embedder is disabled" \
    || bad "default path does not explain the cix-npu state"

# MCP transport: the image's default command is API-only, so the quadlet must
# run the api+mcp supervisor and the installer must provision its auth token.
TPL="$ROOT/assets/agent-stack/mnemos.container"
grep -q '^Exec=mnemos-serve-api-and-mcp' "$TPL" \
    && ok "mnemos quadlet runs the API+MCP supervisor" \
    || bad "mnemos quadlet does NOT run the API+MCP supervisor (MCP unreachable)"
grep -q '^Environment=MNEMOS_MCP_PORT=' "$TPL" \
    && ok "mnemos quadlet sets the MCP port" \
    || bad "mnemos quadlet does NOT set the MCP port"
grep -q '^ContainerName=mnemos' "$TPL" \
    && ok "mnemos quadlet keeps ContainerName=mnemos" \
    || bad "mnemos quadlet lost ContainerName"
grep -q 'MNEMOS_MCP_TOKEN' "$HOOK" \
    && ok "ncz install mnemos provisions the MCP auth token" \
    || bad "ncz install mnemos does NOT provision the MCP auth token"
grep -q 'MNEMOS_MCP_URL' "$HOOK" \
    && ok "ncz install mnemos records the MCP URL in mnemos.env" \
    || bad "ncz install mnemos does NOT record the MCP URL"
grep -q 'mnemos mcp:' "$HOOK" \
    && ok "ncz status surfaces the MCP transport state" \
    || bad "ncz status does NOT surface the MCP transport state"

echo "--- $pass passed, $fail failed"
[ "$fail" = "0" ]
