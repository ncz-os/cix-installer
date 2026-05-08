# Stability Sweep 2 - Post-install Orchestration - 2026-05-08

## 1. Executive summary

- `run-all.sh` is Bash, so the Phase 0 `PIPESTATUS` check is real, not a silent dash/busybox no-op.
- HIGH: the EXIT trap inherited Phase 1 `errexit`; a bootloader failure on an abort path could skip `99-diagnostics.sh`.
- HIGH: `09-diag-account.sh` could fail before seeding SSH keys if `/etc/sudoers.d` did not exist yet.
- Required hooks abort the chain; optional hooks continue and currently leave d-i success unless the bootloader fails.
- Fixes for the HIGH findings, plus required-hook rc preservation, are implemented in `post-install/` only.

## 2. HIGH findings

### H1 - EXIT trap could skip final diagnostics on the highest-value failure path

File: `post-install/run-all.sh:45`, `post-install/run-all.sh:57`, `post-install/run-all.sh:72`

Root cause: Phase 1 enables `set -euo pipefail` at `post-install/run-all.sh:136`.
If `10-our-kernel.sh` or `12-sky1-firmware.sh` failed, `run-all.sh` exited
from inside Phase 1 with `errexit` and `pipefail` still active. The EXIT trap
then ran `70-bootloader.sh` through a pipeline. If that pipeline returned
nonzero, Bash exited the trap immediately before assigning the bootloader rc and
before running `99-diagnostics.sh`.

Impact: the orchestrator promised "bootloader + diagnostics still ran", but the
case where both a required hook and bootloader finalization fail is exactly
where the operator most needs the final state dump. This could leave only a
partial `70-bootloader.log` and no `/var/log/cix-install/99-diagnostics.log`.

Concrete diff implemented:

```diff
diff --git a/post-install/run-all.sh b/post-install/run-all.sh
@@
 finalize_bootloader() {
+    ORIGINAL_RC=$?
+    # The trap may run while Phase 1's `set -euo pipefail` is active.
+    # Keep finalization best-effort so bootloader failure cannot skip
+    # the diagnostics hook.
+    set +e
     BOOTLOADER_RC=0
@@
         bash /usr/local/lib/cix-installer/post-install/99-diagnostics.sh \
-            2>&1 | tee "$LOGDIR/99-diagnostics.log" || \
-            echo "[cix-installer] WARN: 99-diagnostics.sh hit errors"
+            2>&1 | tee "$LOGDIR/99-diagnostics.log"
+        DIAGNOSTICS_RC=${PIPESTATUS[0]}
+        if [ "$DIAGNOSTICS_RC" -ne 0 ]; then
+            echo "[cix-installer] WARN: 99-diagnostics.sh hit errors rc=$DIAGNOSTICS_RC"
+        fi
@@
     if [ "$BOOTLOADER_RC" -ne 0 ]; then
         exit "$BOOTLOADER_RC"
     fi
+    if [ "$ORIGINAL_RC" -ne 0 ]; then
+        exit "$ORIGINAL_RC"
+    fi
 }
```

The fix captures the pre-trap rc, disables `errexit` inside the finalizer, always
attempts diagnostics after bootloader finalization, keeps bootloader failure as
the highest-priority exit code, and otherwise restores the original failure rc.

### H2 - Phase 0 diagnostic account could abort before SSH key seeding

File: `post-install/09-diag-account.sh:50`, `post-install/09-diag-account.sh:52`

Root cause: `09-diag-account.sh` runs before the later `35-ssh.sh` hook that
explicitly installs `sudo`. The hook wrote `/etc/sudoers.d/09-diag-magnetar`
directly under `set -euo pipefail`, but did not ensure `/etc/sudoers.d` existed.
On a minimal target where the `sudo` package had not yet created that directory,
the hook could stop at the sudoers write and never reach the authorized_keys
write at `post-install/09-diag-account.sh:71`.

Impact: Phase 0 could leave a partial `magnetar` account: user and password set,
but no NOPASSWD sudo drop-in and no fleet SSH keys. Later `35-ssh.sh` seeds root
and operator keys, not magnetar keys, so this is not repaired by the normal
optional hook chain.

Concrete diff implemented:

```diff
diff --git a/post-install/09-diag-account.sh b/post-install/09-diag-account.sh
@@
 # Passwordless sudo via dedicated drop-in (so removal is one-line).
 SUDOERS=/etc/sudoers.d/09-diag-magnetar
+install -d -m 0755 /etc/sudoers.d
 cat > "$SUDOERS" <<EOF
```

This keeps the hook idempotent and removes the early dependency on the `sudo`
package's directory creation side effect. If `sudo` is installed later, the
preexisting drop-in is already present.

## 3. MEDIUM findings

### M1 - `late.sh` still bypasses its explicit `RET=$?` path on nonzero `run-all.sh`

File: `preseed/late.sh:21`, `preseed/late.sh:214`, `preseed/late.sh:215`

Root cause: `late.sh` runs under `set -e`, then calls `in-target
/usr/local/lib/cix-installer/post-install/run-all.sh` before assigning `RET=$?`.
If `run-all.sh` returns nonzero, the shell exits at the `in-target` line. d-i
still sees failure, but the local `RET` handling path is skipped, including the
explicit "in-target run-all.sh exited" log line and the bind-mount cleanup block.

Concrete diff not staged in this component because `preseed/*` was explicitly
out of bounds for this sweep:

```diff
diff --git a/preseed/late.sh b/preseed/late.sh
@@
 echo "--- running post-install in chroot ---"
-in-target /usr/local/lib/cix-installer/post-install/run-all.sh
-RET=$?
+set +e
+in-target /usr/local/lib/cix-installer/post-install/run-all.sh
+RET=$?
+set -e
```

Severity is MEDIUM rather than HIGH because the nonzero status still reaches
d-i. The loss is cleanup and evidence, not silent install success.

### M2 - Required hook rc was flattened to `1`

File: `post-install/run-all.sh:148`, `post-install/run-all.sh:150`,
`post-install/run-all.sh:157`

Root cause: the Phase 1 required-hook runner used `if ! bash hook | tee log`;
inside the failure branch, `$?` is the status of the negated conditional, not
the hook rc. The script then exited `1` for any required-hook failure.

Impact: d-i could distinguish success from failure, but not the hook's actual
exit convention. That makes automated take logs and rc-specific triage weaker.

Concrete diff implemented with H1:

```diff
diff --git a/post-install/run-all.sh b/post-install/run-all.sh
@@
-            if ! bash ./"$hook" 2>&1 | tee "$LOG"; then
+            set +e
+            bash ./"$hook" 2>&1 | tee "$LOG"
+            rc=${PIPESTATUS[0]}
+            set -e
+            if [ "$rc" -ne 0 ]; then
@@
-                exit 1
+                exit "$rc"
             fi
```

### M3 - Optional hook failures are not machine-readable after install

File: `post-install/run-all.sh:180`, `post-install/run-all.sh:186`,
`post-install/run-all.sh:198`

Root cause: Phase 2 intentionally continues after optional hook failures and
appends names to `FAILED_HOOKS`. The summary is printed to stdout and mirrored
to tty3, but no stable status file is written under `/var/log/cix-install/`.
During normal d-i invocation, the aggregate stream lands in
`/target/var/log/cix-installer-late.log`; during manual recovery reruns, the
operator must reconstruct optional failures from console scrollback or per-hook
logs.

Impact: optional failures do not fail the install by design, but failures of
hooks like SSH or agent bootstrap can be operator-visible after reboot. Without
a status artifact, take-to-take automation cannot reliably classify "installed
with degraded optional hooks".

Concrete diff recommendation:

```diff
diff --git a/post-install/run-all.sh b/post-install/run-all.sh
@@
 if [ -z "$FAILED_HOOKS" ]; then
     echo "[cix-installer] all optional hooks completed cleanly"
+    rm -f "$LOGDIR/FAILED_HOOKS"
     tty_msg "Phase 2 complete: all optional hooks OK"
 else
     echo "[cix-installer] some optional hooks failed: $FAILED_HOOKS"
+    printf '%s\n' $FAILED_HOOKS > "$LOGDIR/FAILED_HOOKS"
     tty_msg "Phase 2 done with failures:$FAILED_HOOKS"
 fi
```

For stricter release gates, add a later `CIX_POSTINSTALL_STRICT=1` mode that
exits nonzero when `FAILED_HOOKS` is nonempty, while keeping today's default
best-effort behavior for hardware shakedown.

## 4. LOW findings and recommendations

### L1 - Hook ordering is deterministic in the observed environment, but locale is not pinned

File: `post-install/run-all.sh:112`, `post-install/run-all.sh:138`,
`post-install/run-all.sh:168`

Observed sorted order from the repo:

```text
09-diag-account.sh
10-our-kernel.sh
12-sky1-firmware.sh
15-mesa-sky1-pin.sh
20-desktop.sh
22-display-fix.sh
25-cix-ppa.sh
25-cix-proprietary.sh
30-agents.sh
31-remote-access.sh
32-quadlet-shim.sh
33-ntp-hostname.sh
34-fstab.sh
35-fstrim-fix.sh
35-ssh.sh
40-claude-code.sh
45-wallpaper-rotator.sh
46-ncz-cli.sh
47-embedkit.sh
47-llm-stack.sh
48-magnetar-variant.sh
50-brand.sh
56-icon-theme.sh
60-plymouth.sh
70-bootloader.sh
80-npu.sh
99-diagnostics.sh
```

For shared prefixes, `25-cix-ppa.sh` sorts before
`25-cix-proprietary.sh`; `35-fstrim-fix.sh` sorts before `35-ssh.sh`;
`47-embedkit.sh` sorts before `47-llm-stack.sh`. This is deterministic for the
current ASCII names under the current locale, but the orchestrator should pin
`LC_ALL=C` near the top to prevent future locale-dependent surprises.

Recommendation:

```diff
diff --git a/post-install/run-all.sh b/post-install/run-all.sh
@@
 LOGDIR=/var/log/cix-install
+export LC_ALL=C
 mkdir -p "$LOGDIR"
```

### L2 - Phase 0 `PIPESTATUS` is valid because `run-all.sh` is Bash

File: `post-install/run-all.sh:1`, `post-install/run-all.sh:124`,
`post-install/run-all.sh:125`, `preseed/late.sh:214`

No defect found for the requested bashism check. The orchestrator shebang is
`#!/bin/bash`, and `late.sh` invokes it by path through `in-target`, so the
kernel shebang should select Bash inside the chroot. `PIPESTATUS` is therefore
defined for Phase 0, Phase 1, Phase 2, and the finalizer.

Recommendation: do not run recovery as `sh run-all.sh`. Recovery docs should
say:

```sh
chroot /target /usr/local/lib/cix-installer/post-install/run-all.sh
```

### L3 - Idempotence is delegated to hooks; the orchestrator has no resume model

File: `post-install/run-all.sh:112`, `post-install/run-all.sh:138`,
`post-install/run-all.sh:171`

If install crashes in hook 47 and the operator reruns `run-all.sh`, the
orchestrator reruns Phase 0, both required hooks, and all earlier optional hooks.
That is simple and defensible, but it means recovery depends on every earlier
hook being idempotent. This sweep did not audit individual 10-99 hook contents
per scope.

Recommendation: keep rerun-all as the default, but add a documented manual
escape hatch for advanced recovery:

```sh
CIX_POSTINSTALL_FROM=47-embedkit.sh /usr/local/lib/cix-installer/post-install/run-all.sh
```

Do not add this until the hook content audits define which hooks are safe to
skip. A bad resume flag can be worse than a slow rerun.

### L4 - Logging is mostly sound; aggregate run status can be clearer

File: `post-install/run-all.sh:124`, `post-install/run-all.sh:149`,
`post-install/run-all.sh:180`, `post-install/run-all.sh:57`,
`post-install/run-all.sh:72`

Each hook is wrapped with `tee "$LOGDIR/<hook>.log"`, and tty3 receives progress
messages. `70-bootloader.sh` and `99-diagnostics.sh` are also logged in the EXIT
trap. Normal d-i invocation also captures the aggregate stream in
`/target/var/log/cix-installer-late.log` because `late.sh` redirects stdout and
stderr at `preseed/late.sh:25`.

Recommendation: add `/var/log/cix-install/run-all-summary.log` or the
`FAILED_HOOKS` artifact from M3 so manual recovery runs leave the same summary
evidence as d-i runs.

### L5 - Diagnostic key consistency is good on the active Ubuntu preseed path

File: `post-install/09-diag-account.sh:62`, `post-install/09-diag-account.sh:64`,
`post-install/35-ssh.sh:65`, `post-install/35-ssh.sh:70`,
`preseed/preseed-ubuntu.cfg:117`, `preseed/preseed-ubuntu.cfg:124`

The two fleet keys in `09-diag-account.sh` match the key set in `35-ssh.sh` and
the active `preseed/preseed-ubuntu.cfg` early_command. The build script stages
`preseed-ubuntu.cfg` as `/cixmini/preseed.cfg`, so this is the path used by the
current ISO build.

Recommendation: single-source these keys before release. Three embedded copies
are easy to drift during a later rotation.

### L6 - Exit-code conventions are documented in comments, not enforced

File: `post-install/run-all.sh:7`, `post-install/run-all.sh:15`,
`post-install/run-all.sh:165`

The current convention is:

- Phase 0 diagnostic affordance hooks: run early, log rc, never block install.
- Phase 1 required hooks: abort install on failure.
- Phase 2 optional hooks: log failures and continue.
- Finalizer: always attempt bootloader and diagnostics; bootloader failure wins.

Recommendation: add this as a short contract in `docs/` after the content-hook
audits settle which hooks should remain optional. Hooks that intentionally
`exit 0` after best-effort work should say so in their own header.

## 5. Test plan

### Verify H1 - diagnostics always run after required-hook and bootloader failures

1. Build a temporary take20+ debug ISO with a controlled failure near the top of
   `12-sky1-firmware.sh`:

```sh
# Debug ISO only: insert near the top of post-install/12-sky1-firmware.sh.
exit 42
```

   Apply that manually in the debug tree only; do not commit it.

2. Also force `70-bootloader.sh` to fail early in the same debug ISO with
   `exit 55`.

3. Run the install through late_command.

4. Expected result:

```text
/target/var/log/cix-install/70-bootloader.log exists
/target/var/log/cix-install/99-diagnostics.log exists
/target/var/log/cix-install/bootloader-state.log exists
d-i reports late_command failure
run-all.sh final rc is 55 once late.sh captures RET explicitly
```

5. Repeat with only `12-sky1-firmware.sh` forced to `exit 42` and
   `70-bootloader.sh` left real. Expected final rc is 42 if bootloader succeeds,
   and `99-diagnostics.log` still exists.

### Verify H2 - Phase 0 diag account is complete on a minimal target

1. On a take20+ install, inspect the Phase 0 log:

```sh
cat /target/var/log/cix-install/09-diag-account.log
```

2. Expected log lines include:

```text
/etc/sudoers.d/09-diag-magnetar written (NOPASSWD)
/home/magnetar/.ssh/authorized_keys seeded
Diagnostic account ready
```

3. Before reboot or from rescue, verify files on the target:

```sh
chroot /target id magnetar
test -f /target/etc/sudoers.d/09-diag-magnetar
test -s /target/home/magnetar/.ssh/authorized_keys
```

4. After first boot, verify both access paths:

```sh
ssh magnetar@<host> true
ssh magnetar@<host> 'sudo -n true'
```

### Verify error propagation and logs generally

1. For a required hook failure, confirm:

```text
/target/var/log/cix-install/<required-hook>.log contains the hook failure
/target/var/log/cix-install/99-diagnostics.log exists
d-i reports a failed late_command
```

2. For an optional hook failure, force a temporary nonzero exit in one optional
   hook in a debug ISO. Expected current behavior:

```text
run-all.sh continues to later optional hooks
70-bootloader.sh runs
99-diagnostics.sh runs
install exits 0 if bootloader succeeds
failed hook name appears in cix-installer-late.log
```

3. Verify ordering in the installed log stream:

```text
09-diag-account.sh runs before 10-our-kernel.sh
25-cix-ppa.sh runs before 25-cix-proprietary.sh
35-fstrim-fix.sh runs before 35-ssh.sh
47-embedkit.sh runs before 47-llm-stack.sh
80-npu.sh runs before the EXIT-trap bootloader
99-diagnostics.sh runs after 70-bootloader.sh
```

4. Verify Phase 0 Bash behavior by checking that a temporary `exit 13` in
   `09-diag-account.sh` is reported as rc 13 in tty3 and
   `/var/log/cix-install/09-diag-account.log`, while Phase 1 still starts.

## Staging note

Staged fixes should include only:

```text
post-install/09-diag-account.sh
post-install/run-all.sh
docs/STABILITY-SWEEP-2-POSTINSTALL-ORCH-2026-05-08.md
```

Existing unrelated untracked files in this checkout are intentionally ignored.
