# Stability Sweep 1 - Preseed / Install-Time Scripts - 2026-05-08

Scope: `preseed/preseed-ubuntu.cfg`, `preseed/sshd-watcher.sh`,
`preseed/late.sh`, `preseed/extract-rootfs.sh`, legacy
`preseed/preseed.cfg`, and `tools/di-diag.sh`.

Baseline audited: branch `r75-review`, commit
`bb6514287adb870de88474601a936418dfd9da77`.

External hook semantics checked against Debian Installer internals:

- https://d-i.debian.org/doc/internals/apb.html
- https://sources.debian.org/src/base-installer/1.213/library.sh/

## Executive summary

- Verdict: this layer is close, but not yet "leave it alone"; two HIGH gaps were found and fixed in place.
- Findings: 2 HIGH, 3 MEDIUM, 5 LOW/recommendations.
- No active d-i ramdisk script uses `[[`, bash substrings, `pgrep`, `nohup`, `setsid`, or `flock`; syntax checks pass under `/bin/sh`.
- Highest install risk was non-atomic DNS hook publication in the watcher; staged fix publishes hooks and `/target/etc/resolv.conf` via temp-file plus atomic `mv`.
- Highest operator risk was `di-diag.sh` waiting for an end marker before sending it; staged fix sends a unique marker immediately after the remote command and propagates remote rc.

## HIGH findings

### HIGH-1 - DNS hooks were published non-atomically

Pre-fix citation: `preseed/sshd-watcher.sh:52`, `preseed/sshd-watcher.sh:63-64`,
`preseed/sshd-watcher.sh:77-78`.

Root cause: the watcher wrote `/usr/lib/base-installer.d/05ncz-dns` directly
with `cat > final`, made it executable, then copied it into `pre-pkgsel.d`.
The generated hook also removed `/target/etc/resolv.conf` and then wrote the
replacement directly. Because the watcher runs under `set +e`, an interrupted
write, ramdisk write failure, or restart at the wrong moment could leave a
truncated hook or a missing/partial resolver file exactly when base-installer
or pkgsel was about to run apt in `/target`.

Why HIGH: this is directly on the install-critical DNS path that caused
take15-19 failures. A partial or missing hook can regress the fix back to a
single resolver and make `apt-get update` or pkgsel fail.

Concrete patch applied:

```diff
diff --git a/preseed/sshd-watcher.sh b/preseed/sshd-watcher.sh
@@
-    cat > /usr/lib/base-installer.d/05ncz-dns <<'NCZDNSHOOK'
+    write_ncz_dns_hook() {
+        hook_dir="$1"
+        hook_tmp="$hook_dir/.05ncz-dns.$$"
+        hook_final="$hook_dir/05ncz-dns"
+        rm -f "$hook_tmp"
+        cat > "$hook_tmp" <<'NCZDNSHOOK'
@@
-    rm -f /target/etc/resolv.conf
-    cat > /target/etc/resolv.conf <<EOF
+    rc_tmp="/target/etc/.resolv.conf.ncz.$$"
+    rm -f "$rc_tmp"
+    cat > "$rc_tmp" <<EOF
 search nclawzero.lan
 nameserver $router
 nameserver 8.8.8.8
 nameserver 1.1.1.1
 options timeout:2 attempts:3
 EOF
-    echo "[ncz-dns] wrote /target/etc/resolv.conf router=$router at $(date -u +%FT%TZ)" >> "$LOG"
+    if grep -q '^options timeout:2 attempts:3$' "$rc_tmp" && mv -f "$rc_tmp" /target/etc/resolv.conf; then
+        echo "[ncz-dns] wrote /target/etc/resolv.conf router=$router at $(date -u +%FT%TZ)" >> "$LOG"
+    else
+        rm -f "$rc_tmp"
+        echo "[ncz-dns] failed to publish /target/etc/resolv.conf at $(date -u +%FT%TZ)" >> "$LOG"
+    fi
@@
-    chmod 0755 /usr/lib/base-installer.d/05ncz-dns
-    cp /usr/lib/base-installer.d/05ncz-dns /usr/lib/pre-pkgsel.d/05ncz-dns
+        if grep -q '^exit 0$' "$hook_tmp" && chmod 0755 "$hook_tmp" && mv -f "$hook_tmp" "$hook_final"; then
+            :
+        else
+            rm -f "$hook_tmp"
+            echo "[watcher] failed to publish $hook_final"
+        fi
+    }
+    write_ncz_dns_hook /usr/lib/base-installer.d
+    write_ncz_dns_hook /usr/lib/pre-pkgsel.d
```

Notes:

- The d-i hook locations are correct. Debian Installer documents both
  `/usr/lib/base-installer.d/*` and `/usr/lib/pre-pkgsel.d/*` as run-parts
  style hooks.
- `base-installer.d` scripts are invoked without arguments by
  `base-installer`. `pre-pkgsel.d` may pass a progress argument on some pkgsel
  versions; this hook ignores positional args and emits no stdout, which is
  acceptable because it does not move progress.
- The hook heredoc delimiters are unambiguous: outer delimiter is
  `NCZDNSHOOK`; inner resolver delimiter is `EOF`.

### HIGH-2 - `di-diag.sh` waited for a marker before sending it

Pre-fix citation: `tools/di-diag.sh:137-143`.

Root cause: for one-shot commands, the expect driver sent `$cmd`, then waited
for `MARK_END_RUN` or `DI_PHASE_END`, but did not send `MARK_END_RUN` until
after that wait. Any non-`diag` command that did not print one of those strings
would sit for 120 seconds and emit `command timed out` even if the command had
already completed. That makes install-failure evidence collection slow and
ambiguous.

Why HIGH: this tool is the recovery path when d-i is on a red failure dialog.
A false timeout can hide the exact state the operator needs before main-menu
changes state or SSH drops.

Concrete patch applied:

```diff
diff --git a/tools/di-diag.sh b/tools/di-diag.sh
@@
 spawn ssh -tt \
@@
     -o NumberOfPasswordPrompts=1 \
+    -o ConnectTimeout=15 \
     -o ServerAliveInterval=20 \
+    -o ServerAliveCountMax=3 \
     installer@$host
@@
 } else {
     set timeout 120
+    set marker "MARK_END_RUN_[pid]_[clock seconds]"
+    set remote_rc 0
@@
     send -- "$cmd\r"
+    send -- "rc=\$?; echo $marker:\$rc\r"
     expect {
-        -re "MARK_END_RUN" { }
-        -re "DI_PHASE_END" { }
-        timeout { send_user "\ncommand timed out\n" }
-    }
-    send -- "echo MARK_END_RUN\r"
-    expect {
-        -re "MARK_END_RUN\r\n.*# " { }
-        timeout { }
+        -re "$marker:([0-9]+)" { set remote_rc $expect_out(1,string) }
+        timeout {
+            send_user "\ncommand timed out waiting for completion marker\n"
+            set remote_rc 124
+        }
+        eof {
+            send_user "\nssh closed before completion marker\n"
+            exit 6
+        }
     }
@@
-    expect eof
+    expect {
+        eof { }
+        timeout { send_user "\ntimeout waiting for ssh close\n" }
+    }
+    exit $remote_rc
 }
```

The canned `diag` command was also collapsed to a single remote shell string
with explicit ShellCheck suppressions around the intentional command transport.

## MEDIUM findings

### MEDIUM-1 - `late.sh` failure handling is bypassed by `set -e`

Citation: `preseed/late.sh:21`, `preseed/late.sh:214-221`.

Root cause: `late.sh` uses `set -e`, then runs:

```sh
in-target /usr/local/lib/cix-installer/post-install/run-all.sh
RET=$?
```

If `run-all.sh` returns nonzero, the shell exits before `RET=$?`, before the
bind mount cleanup, and before the explicit `in-target run-all.sh exited: ...`
log line. The install still fails, but the failure path loses useful evidence
and may leave `/target/cdrom` mounted.

Concrete patch:

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

Leave unstaged for this sweep because it is not the take19 DNS failure path,
but it is a straightforward next fix.

### MEDIUM-2 - cdrom apt update pipeline hides apt failure

Citation: `preseed/late.sh:163-164`.

Root cause: POSIX shell returns the status of the last command in a pipeline.
`in-target apt-get update 2>&1 | tail -3 || ...` tests `tail`, not
`apt-get update`. A failed cdrom apt update can therefore look successful.

Concrete patch:

```diff
diff --git a/preseed/late.sh b/preseed/late.sh
@@
-    in-target apt-get update 2>&1 | tail -3 || \
-        { echo "WARN: in-target apt-get update from cdrom failed"; }
+    APT_UPDATE_LOG=/target/var/log/cix-installer-cdrom-apt-update.log
+    if in-target apt-get update >"$APT_UPDATE_LOG" 2>&1; then
+        tail -3 "$APT_UPDATE_LOG" || true
+    else
+        tail -20 "$APT_UPDATE_LOG" || true
+        echo "WARN: in-target apt-get update from cdrom failed"
+    fi
```

### MEDIUM-3 - obsolete udhcpc override is still installed

Citation: `preseed/sshd-watcher.sh:97-140` at baseline.

Root cause: the script comments say take18 stopped using the udhcpc writer as
the DNS source of truth, and take19 added deterministic d-i hooks. The old
`/etc/udhcpc/default.script` replacement remains. It manually configures IP and
routes with busybox `ip`/`ifconfig`/`route`, then writes `/etc/resolv.conf`.
That is now redundant with the watcher loop and hooks, and it is riskier than
leaving d-i/netcfg's DHCP plumbing alone.

Concrete patch:

```diff
diff --git a/preseed/sshd-watcher.sh b/preseed/sshd-watcher.sh
@@
-mkdir -p /etc/udhcpc
-cat > /etc/udhcpc/default.script <<'UDHCPCDEFAULT'
-...
-UDHCPCDEFAULT
-chmod +x /etc/udhcpc/default.script
-echo "[watcher] installed custom /etc/udhcpc/default.script for resolv.conf fallback chain"
+echo "[watcher] leaving d-i udhcpc/default.script untouched; DNS handled by hooks/watch loop"
```

Do this in the next bake after confirming whether netcfg on the active initrd
uses `/etc/udhcpc/default.script` directly or invokes udhcpc with its own script
path. I did not stage it because removing DHCP plumbing is a behavior change
outside the two clear HIGH fixes.

## LOW findings + recommendations

### LOW-1 - `preseed/preseed.cfg` is legacy but says it is canonical

Citation: `preseed/preseed.cfg:3-4`.

`build/build-iso-di.sh` stages `preseed/preseed-ubuntu.cfg` into
`/cixmini/preseed.cfg`, but the legacy file still says it is canonical. Also,
the old `Makefile` path references `$(PRESEED)/preseed.cfg` in its dependency
list. Recommendation: change the header to say "LEGACY - not used by
build/build-iso-di.sh" and clean the legacy build docs in a separate build
audit.

### LOW-2 - Hard-coded install disk remains intentional but brittle

Citation: `preseed/preseed-ubuntu.cfg:233-242`,
`preseed/preseed-ubuntu.cfg:253`.

The active preseed destructively targets `/dev/nvme0n1`. That is acceptable for
the .66 hardware path if the operator expects that device, but it will fail on
virtio (`/dev/vda`) and is dangerous on multi-NVMe hosts. Do not redesign this
inside the preseed script sweep; test media should confirm the target disk name
before unattended runs.

### LOW-3 - `extract-rootfs.sh` loses tar stderr from the main log

Citation: `preseed/extract-rootfs.sh:94-101`.

The checkpoint tar path redirects stderr to `/dev/tty3`, despite the comment
saying output goes to the log and tty. If extraction fails, the log may only
show the retry line and final rc. Recommendation: capture tar stderr to a temp
file and replay a tail into both `$LOG` and `$TTY`.

### LOW-4 - Applet assumptions should be verified on the live initrd

Citation: `preseed/sshd-watcher.sh:180-206`,
`preseed/extract-rootfs.sh:52`, `preseed/extract-rootfs.sh:94-96`.

The active scripts avoid bashisms, but still depend on busybox applets/features:
`ip route`, `awk`, `cmp`, `readlink -f`, `dirname`, `mountpoint`, and GNU tar
checkpoint support. Most are guarded or have fallbacks. Recommendation: add a
one-shot `di-diag` command to print `busybox --list` or `command -v` for those
applets during take20 evidence capture.

### LOW-5 - `pkgsel/upgrade full-upgrade` increases network exposure

Citation: `preseed/preseed-ubuntu.cfg:326`.

`pkgsel/include` is intentionally small, and both recommend toggles are present
at `preseed/preseed-ubuntu.cfg:340-347`. However, `pkgsel/upgrade` is still
`full-upgrade`, which can expand the install-time apt work in netinstall mode.
Recommendation: consider `pkgsel/upgrade select none` for the netinstall build
variant if take20 still shows DNS-sensitive pkgsel behavior.

## Test plan

### HIGH-1 evidence - atomic DNS hook publication

Run after early_command and before pkgsel:

```sh
tools/di-diag.sh 192.168.207.66 'echo HOOKS; ls -l /usr/lib/base-installer.d/05ncz-dns /usr/lib/pre-pkgsel.d/05ncz-dns 2>&1; echo TMP; ls /usr/lib/base-installer.d/.05ncz-dns.* /usr/lib/pre-pkgsel.d/.05ncz-dns.* 2>&1; echo BODY; sed -n "1,40p" /usr/lib/base-installer.d/05ncz-dns; echo LOG; grep -E "\[watcher\] installed ncz DNS|\[watcher\] failed to publish|\[ncz-dns\]" /var/log/early_command.log 2>&1 | tail -30; echo TARGET; ls -l /target/etc/resolv.conf 2>&1; cat /target/etc/resolv.conf 2>&1'
```

Expected evidence:

- Both hook files exist and are executable.
- No `.05ncz-dns.*` temp file remains in either hook directory.
- Hook body contains `rc_tmp="/target/etc/.resolv.conf.ncz.$$"` and
  `mv -f "$rc_tmp" /target/etc/resolv.conf`.
- `/var/log/early_command.log` contains the watcher install line and later an
  `[ncz-dns] wrote /target/etc/resolv.conf ...` line.
- No `[watcher] failed to publish ...` and no `[ncz-dns] failed to publish ...`
  line appears.
- `/target/etc/resolv.conf` is a regular file with router, `8.8.8.8`, and
  `1.1.1.1`.

### HIGH-2 evidence - `di-diag.sh` completion marker

Run from the operator machine:

```sh
time tools/di-diag.sh 192.168.207.66 'echo hello'
tools/di-diag.sh 192.168.207.66 'false'; echo "rc=$?"
tools/di-diag.sh 192.168.207.66 'sleep 130'; echo "rc=$?"
```

Expected evidence:

- `echo hello` returns quickly, not after 120 seconds.
- Output contains `MARK_BEGIN_RUN` and a unique `MARK_END_RUN_*:0`.
- `false` exits locally with `rc=1`.
- `sleep 130` times out around 120 seconds, prints
  `command timed out waiting for completion marker`, and exits `rc=124`.

### Local verification already run

```sh
sh -n preseed/sshd-watcher.sh
sh -n preseed/late.sh
sh -n preseed/extract-rootfs.sh
bash -n tools/di-diag.sh
shellcheck -s sh preseed/sshd-watcher.sh
shellcheck tools/di-diag.sh
```

All six commands passed after the staged HIGH fixes. `shellcheck` still reports
only informational findings in `late.sh` and `extract-rootfs.sh` when run
against the broader scope; those are covered above as medium/low follow-ups.

