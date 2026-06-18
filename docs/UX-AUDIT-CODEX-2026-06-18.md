# NCZ 26.6 (Reinhardt/Magnetar) UX + Configuration Audit

Date: 2026-06-18  
Auditor: Codex (read-only analysis over SSH)

## Executive Summary

This audit focused on end-user experience and configuration correctness for the `cix-installer` hook chain driven by `post-install/run-all.sh` (`0[0-9]-*.sh` then `[0-9][0-9]-*.sh`).

What looks good:
- Desktop/server variant gating is broadly correct (desktop hooks early-exit for `BUILD_VARIANT=server`).
- Wayland sessions are explicitly disabled and XFCE/LightDM/Xorg is enforced (aligned with Mali/Panthor constraints).
- The previously reported issues appear addressed: hostname hook now matches the runner glob, diag account is hidden in greeter, and LightDM greeter background is set.

Main concerns:
- A **security-critical diagnostics posture** is still baked into installed systems (hardcoded diagnostic credentials + permissive SSH policy).
- There are still **silent-success patterns** that can ship missing functionality while install appears successful.
- A few UX defaults conflict (DPMS/blanking/lock behavior), and one launcher path in desktop setup appears to silently no-op.

---

## Genuine Functional Bugs (Prominent)

1. `post-install/20-desktop.sh` copies `/install_ncz_agents.sh` from a path not staged by this repo and does so before strict mode; failure is silent and the Desktop launcher disappears.
2. `post-install/25-cix-proprietary.sh` intentionally swallows package failures and force-exits 0, so Cix userspace can be partially missing while installer reports success.
3. Browser compatibility wrapper hardwires `chromium-browser` -> `vivaldi-stable` even if Vivaldi install fails, creating broken default browser behavior.
4. Display power management policy is internally conflicting (`xorg.conf` disables DPMS while `~/.xscreensaver` enables it and lock=true), producing inconsistent appliance behavior.

---

## Critical Findings

### 1) Factory image ships diagnostic credentials and permissive SSH defaults
- **File refs:** `post-install/09-diag-account.sh`, `post-install/35-ssh.sh`, `preseed/preseed-ubuntu.cfg`, `preseed/preseed.cfg`
- **What is wrong / symptom:**
  - `magnetar` diagnostic account with known password (`diags`) + `NOPASSWD:ALL` is created by default.
  - Preseed network-console password is `diags`.
  - SSH config drop-in enables `PermitRootLogin yes` and `PasswordAuthentication yes`.
  - Net effect: predictable credentials and broad remote auth surface on first boot.
- **Recommended fix (exact snippet):**
```diff
# post-install/09-diag-account.sh
- DIAG_USER=magnetar
- DIAG_PASS=diags
+ DIAG_USER=${DIAG_USER:-magnetar}
+ DIAG_PASS=${DIAG_PASS:-}
+
+ if [ "${NCZ_ENABLE_DIAG_ACCOUNT:-0}" != "1" ]; then
+   echo "[09] diag account disabled by default (NCZ_ENABLE_DIAG_ACCOUNT!=1)"
+   exit 0
+ fi
+
+ if [ -z "$DIAG_PASS" ]; then
+   echo "[09] ERROR: NCZ_ENABLE_DIAG_ACCOUNT=1 but DIAG_PASS is empty" >&2
+   exit 1
+ fi
```
```diff
# post-install/35-ssh.sh
- PermitRootLogin yes
- PasswordAuthentication yes
- KbdInteractiveAuthentication yes
+ PermitRootLogin prohibit-password
+ PasswordAuthentication no
+ KbdInteractiveAuthentication no
  ChallengeResponseAuthentication no
  PubkeyAuthentication yes
```
```diff
# preseed/preseed-ubuntu.cfg + preseed/preseed.cfg
- d-i network-console/password password diags
- d-i network-console/password-again password diags
+ # do not bake static diagnostics password into release images
+ # set interactively or inject only in explicit debug builds
```
- **Risk / effort:** High risk, medium effort. Should be release-blocking for non-lab images.

### 2) Proprietary stack hook can silently "succeed" with missing runtime pieces
- **File refs:** `post-install/25-cix-proprietary.sh` (especially failure-tolerant `dpkg/apt` blocks and final `exit 0`)
- **What is wrong / symptom:**
  - The hook logs and continues through `dpkg -i`, `apt-get -fy`, `dpkg --configure -a`, purges broken packages, and always exits success.
  - Result can be partially installed Cix userspace/NPU libs with no hard installer failure signal.
  - User-visible symptom: post-boot NPU/GPU features fail unexpectedly despite "successful" install.
- **Recommended fix (exact snippet):**
```diff
# post-install/25-cix-proprietary.sh
- dpkg -i --force-depends "${DEBS[@]}" ... || true
- apt-get install -fy ... || true
- dpkg --configure -a ... || true
+ dpkg -i --force-depends "${DEBS[@]}" ... || RC=1
+ apt-get install -fy ... || RC=1
+ dpkg --configure -a ... || RC=1
...
- exit 0
+ # Require minimum viable runtime on desktop/server variants
+ required_paths=(/usr/share/cix/lib/libnoe.so)
+ for p in "${required_paths[@]}"; do
+   [ -e "$p" ] || RC=1
+ done
+ exit "${RC:-0}"
```
- **Risk / effort:** High risk, medium effort. Strongly recommended to avoid silent broken builds.

---

## High Findings

### 3) Desktop agent launcher copy source appears invalid and silently no-ops
- **File refs:** `post-install/20-desktop.sh` (top lines)
- **What is wrong / symptom:**
  - Script does `cp "/install_ncz_agents.sh" /etc/skel/Desktop/` before `set -euo pipefail`.
  - No matching source path is present in this repo payload; copy failure is ignored by timing.
  - User-visible symptom: expected desktop installer shortcut may never appear.
- **Recommended fix (exact snippet):**
```diff
# post-install/20-desktop.sh
- cp "/install_ncz_agents.sh" /etc/skel/Desktop/
- chmod +x /etc/skel/Desktop/install_ncz_agents.sh
+ set -euo pipefail
+ install -d -m 0755 /etc/skel/Desktop
+ if [ -f /usr/local/lib/cix-installer/assets/agent-stack/install_ncz_agents.sh ]; then
+   install -m 0755 /usr/local/lib/cix-installer/assets/agent-stack/install_ncz_agents.sh \
+     /etc/skel/Desktop/install_ncz_agents.sh
+ else
+   echo "[20] WARN: install_ncz_agents.sh not staged; skipping Desktop launcher"
+ fi
```
- **Risk / effort:** Medium risk, low effort.

### 4) Browser default path can break when Vivaldi fetch/install fails
- **File refs:** `post-install/20-desktop.sh` (Vivaldi install + wrapper/default blocks)
- **What is wrong / symptom:**
  - Vivaldi install is best-effort; failures are tolerated.
  - Later, wrapper hardcodes `exec /usr/bin/vivaldi-stable "$@"` and defaults are set to Vivaldi.
  - If Vivaldi is absent (network/repo hiccup), `chromium-browser` alias and link-open behavior can fail.
- **Recommended fix (exact snippet):**
```diff
# post-install/20-desktop.sh
+ BROWSER_BIN=""
+ if command -v vivaldi-stable >/dev/null 2>&1; then
+   BROWSER_BIN=/usr/bin/vivaldi-stable
+ elif flatpak info org.chromium.Chromium >/dev/null 2>&1; then
+   BROWSER_BIN="/usr/bin/flatpak run org.chromium.Chromium"
+ elif command -v falkon >/dev/null 2>&1; then
+   BROWSER_BIN=/usr/bin/falkon
+ fi
+
+ [ -n "$BROWSER_BIN" ] || { echo "[20] ERROR: no browser installed" >&2; exit 1; }
```
```diff
# wrapper
- exec /usr/bin/vivaldi-stable "$@"
+ exec sh -lc -- ssh -o ConnectTimeout=15 jasonperlow@192.168.207.22 'cd ~/cix-installer-build/cix-installer && cat > docs/UX-AUDIT-CODEX-2026-06-18.md <<"EOF"
# NCZ 26.6 (Reinhardt/Magnetar) UX + Configuration Audit

Date: 2026-06-18  
Auditor: Codex (read-only analysis over SSH)

## Executive Summary

This audit focused on end-user experience and configuration correctness for the `cix-installer` hook chain driven by `post-install/run-all.sh` (`0[0-9]-*.sh` then `[0-9][0-9]-*.sh`).

What looks good:
- Desktop/server variant gating is broadly correct (desktop hooks early-exit for `BUILD_VARIANT=server`).
- Wayland sessions are explicitly disabled and XFCE/LightDM/Xorg is enforced (aligned with Mali/Panthor constraints).
- The previously reported issues appear addressed: hostname hook now matches the runner glob, diag account is hidden in greeter, and LightDM greeter background is set.

Main concerns:
- A **security-critical diagnostics posture** is still baked into installed systems (hardcoded diagnostic credentials + permissive SSH policy).
- There are still **silent-success patterns** that can ship missing functionality while install appears successful.
- A few UX defaults conflict (DPMS/blanking/lock behavior), and one launcher path in desktop setup appears to silently no-op.

---

## Genuine Functional Bugs (Prominent)

1. `post-install/20-desktop.sh` copies `/install_ncz_agents.sh` from a path not staged by this repo and does so before strict mode; failure is silent and the Desktop launcher disappears.
2. `post-install/25-cix-proprietary.sh` intentionally swallows package failures and force-exits 0, so Cix userspace can be partially missing while installer reports success.
3. Browser compatibility wrapper hardwires `chromium-browser` -> `vivaldi-stable` even if Vivaldi install fails, creating broken default browser behavior.
4. Display power management policy is internally conflicting (`xorg.conf` disables DPMS while `~/.xscreensaver` enables it and lock=true), producing inconsistent appliance behavior.

---

## Critical Findings

### 1) Factory image ships diagnostic credentials and permissive SSH defaults
- **File refs:** `post-install/09-diag-account.sh`, `post-install/35-ssh.sh`, `preseed/preseed-ubuntu.cfg`, `preseed/preseed.cfg`
- **What is wrong / symptom:**
  - `magnetar` diagnostic account with known password (`diags`) + `NOPASSWD:ALL` is created by default.
  - Preseed network-console password is `diags`.
  - SSH config drop-in enables `PermitRootLogin yes` and `PasswordAuthentication yes`.
  - Net effect: predictable credentials and broad remote auth surface on first boot.
- **Recommended fix (exact snippet):**
```diff
# post-install/09-diag-account.sh
- DIAG_USER=magnetar
- DIAG_PASS='diags'
+ DIAG_USER=${DIAG_USER:-magnetar}
+ DIAG_PASS=${DIAG_PASS:-}
+
+ if [ "${NCZ_ENABLE_DIAG_ACCOUNT:-0}" != "1" ]; then
+   echo "[09] diag account disabled by default (NCZ_ENABLE_DIAG_ACCOUNT!=1)"
+   exit 0
+ fi
+
+ if [ -z "$DIAG_PASS" ]; then
+   echo "[09] ERROR: NCZ_ENABLE_DIAG_ACCOUNT=1 but DIAG_PASS is empty" >&2
+   exit 1
+ fi
```
```diff
# post-install/35-ssh.sh
- PermitRootLogin yes
- PasswordAuthentication yes
- KbdInteractiveAuthentication yes
+ PermitRootLogin prohibit-password
+ PasswordAuthentication no
+ KbdInteractiveAuthentication no
  ChallengeResponseAuthentication no
  PubkeyAuthentication yes
```
```diff
# preseed/preseed-ubuntu.cfg + preseed/preseed.cfg
- d-i network-console/password password diags
- d-i network-console/password-again password diags
+ # do not bake static diagnostics password into release images
+ # set interactively or inject only in explicit debug builds
```
- **Risk / effort:** High risk, medium effort. Should be release-blocking for non-lab images.

### 2) Proprietary stack hook can silently "succeed" with missing runtime pieces
- **File refs:** `post-install/25-cix-proprietary.sh` (especially failure-tolerant `dpkg/apt` blocks and final `exit 0`)
- **What is wrong / symptom:**
  - The hook logs and continues through `dpkg -i`, `apt-get -fy`, `dpkg --configure -a`, purges broken packages, and always exits success.
  - Result can be partially installed Cix userspace/NPU libs with no hard installer failure signal.
  - User-visible symptom: post-boot NPU/GPU features fail unexpectedly despite "successful" install.
- **Recommended fix (exact snippet):**
```diff
# post-install/25-cix-proprietary.sh
- dpkg -i --force-depends "${DEBS[@]}" ... || true
- apt-get install -fy ... || true
- dpkg --configure -a ... || true
+ dpkg -i --force-depends "${DEBS[@]}" ... || RC=1
+ apt-get install -fy ... || RC=1
+ dpkg --configure -a ... || RC=1
...
- exit 0
+ # Require minimum viable runtime on desktop/server variants
+ required_paths=(/usr/share/cix/lib/libnoe.so)
+ for p in "${required_paths[@]}"; do
+   [ -e "$p" ] || RC=1
+ done
+ exit "${RC:-0}"
```
- **Risk / effort:** High risk, medium effort. Strongly recommended to avoid silent broken builds.

---

## High Findings

### 3) Desktop agent launcher copy source appears invalid and silently no-ops
- **File refs:** `post-install/20-desktop.sh` (top lines)
- **What is wrong / symptom:**
  - Script does `cp "/install_ncz_agents.sh" /etc/skel/Desktop/` before `set -euo pipefail`.
  - No matching source path is present in this repo payload; copy failure is ignored by timing.
  - User-visible symptom: expected desktop installer shortcut may never appear.
- **Recommended fix (exact snippet):**
```diff
# post-install/20-desktop.sh
- cp "/install_ncz_agents.sh" /etc/skel/Desktop/
- chmod +x /etc/skel/Desktop/install_ncz_agents.sh
+ set -euo pipefail
+ install -d -m 0755 /etc/skel/Desktop
+ if [ -f /usr/local/lib/cix-installer/assets/agent-stack/install_ncz_agents.sh ]; then
+   install -m 0755 /usr/local/lib/cix-installer/assets/agent-stack/install_ncz_agents.sh \
+     /etc/skel/Desktop/install_ncz_agents.sh
+ else
+   echo "[20] WARN: install_ncz_agents.sh not staged; skipping Desktop launcher"
+ fi
```
- **Risk / effort:** Medium risk, low effort.

### 4) Browser default path can break when Vivaldi fetch/install fails
- **File refs:** `post-install/20-desktop.sh` (Vivaldi install + wrapper/default blocks)
- **What is wrong / symptom:**
  - Vivaldi install is best-effort; failures are tolerated.
  - Later, wrapper hardcodes `exec /usr/bin/vivaldi-stable "$@"` and defaults are set to Vivaldi.
  - If Vivaldi is absent (network/repo hiccup), `chromium-browser` alias and link-open behavior can fail.
- **Recommended fix (exact snippet):**
```diff
# post-install/20-desktop.sh
+ BROWSER_BIN=""
+ if command -v vivaldi-stable >/dev/null 2>&1; then
+   BROWSER_BIN=/usr/bin/vivaldi-stable
+ elif flatpak info org.chromium.Chromium >/dev/null 2>&1; then
+   BROWSER_BIN="/usr/bin/flatpak run org.chromium.Chromium"
+ elif command -v falkon >/dev/null 2>&1; then
+   BROWSER_BIN=/usr/bin/falkon
+ fi
+
+ [ -n "$BROWSER_BIN" ] || { echo "[20] ERROR: no browser installed" >&2; exit 1; }
```
```diff
# wrapper
- exec /usr/bin/vivaldi-stable "$@"
+ exec sh -lc '"$0" "$@"' "$BROWSER_BIN" "$@"
```
- **Risk / effort:** Medium-high risk, low-medium effort.

### 5) NetworkManager correctness is optional-phase only despite being connectivity-critical
- **File refs:** `post-install/33-network.sh`, `post-install/run-all.sh`
- **What is wrong / symptom:**
  - `33-network.sh` hard-fails if `network-manager` missing, but Phase 2 treats all such failures as non-fatal.
  - Install can complete with no guaranteed first-boot network if this hook fails.
- **Recommended fix (exact snippet):**
```diff
# post-install/run-all.sh (required list)
- 10-our-kernel.sh|12-sky1-firmware.sh)
+ 10-our-kernel.sh|12-sky1-firmware.sh|33-network.sh)
```
_or add a Phase 1.5 for required post-network hooks._
- **Risk / effort:** High operational risk, low-medium effort.

### 6) DPMS/screen lock policy conflicts between Xorg and xscreensaver
- **File refs:** `post-install/22-display-fix.sh`, `post-install/20-desktop.sh`
- **What is wrong / symptom:**
  - Xorg config disables DPMS/blanking at server level.
  - Default `~/.xscreensaver` enables DPMS and lock after 10 min.
  - Appliance behavior becomes inconsistent across displays/sessions (unexpected lock/blank or no-op depending on path).
- **Recommended fix (exact snippet):**
```diff
# choose one policy for appliance default (example: no auto-lock)
# post-install/20-desktop.sh in .xscreensaver template
- lock:           True
- dpmsEnabled:    True
+ lock:           False
+ dpmsEnabled:    False
```
_and document secure mode as an explicit operator toggle._
- **Risk / effort:** Medium risk, low effort.

---

## Medium Findings

### 7) `50-brand.sh` appears truncated and logs non-existent greeter branding variables
- **File refs:** `post-install/50-brand.sh`
- **What is wrong / symptom:**
  - Script now writes textual OS identity (`os-release`, `issue`, `motd`) but ends with:
    `echo "[50] LightDM greeter rebranded — bg=$NCZ_GREETER_BG, user-img=$NCZ_USER_IMG"`
  - Variables are never defined in this script; no greeter/user image branding occurs here.
  - Symptom: misleading logs and unclear ownership of visual branding behavior.
- **Recommended fix (exact snippet):**
```diff
# post-install/50-brand.sh
- echo "[50] LightDM greeter rebranded — bg=$NCZ_GREETER_BG, user-img=$NCZ_USER_IMG"
+ echo "[50] text branding applied (os-release/issue/motd)"
```
_or actually implement greeter branding in this hook and define those vars._
- **Risk / effort:** Low-medium risk, low effort.

### 8) Chroot-time `systemctl enable --now ... || true` patterns hide service activation mistakes
- **File refs:** e.g. `post-install/20-desktop.sh` (`ncx-upstream-watch.timer`)
- **What is wrong / symptom:**
  - `--now` in chroot is fragile; failures are ignored.
  - Depending on unit/systemctl behavior, enablement may not be guaranteed and logs become noisy.
- **Recommended fix (exact snippet):**
```diff
- systemctl enable --now ncx-upstream-watch.timer 2>&1 | tail -2 || true
+ systemctl enable ncx-upstream-watch.timer 2>&1 | tail -2
+ systemctl start ncx-upstream-watch.timer 2>&1 | tail -2 || true
```
- **Risk / effort:** Medium risk, low effort.

### 9) Shipping `.patch`/`.rej` artifacts in preseed payload is a release hygiene and trust issue
- **File refs:** `preseed/late.sh.patch`, `preseed/late.sh.rej`
- **What is wrong / symptom:**
  - Installer payload includes conflict residue files.
  - Symptom: operator confusion, uncertainty about whether live script reflects intended patch; avoidable footprint noise.
- **Recommended fix (exact snippet):**
```diff
# remove from tree
- preseed/late.sh.patch
- preseed/late.sh.rej
```
```diff
# .gitignore
+ *.rej
+ *.orig
+ *.patch
```
- **Risk / effort:** Low operational risk, very low effort.

### 10) Timezone defaults diverge by preseed path
- **File refs:** `preseed/preseed.cfg` (UTC), `preseed/preseed-ubuntu.cfg` (America/New_York)
- **What is wrong / symptom:**
  - Different installer paths produce different default timezone behavior.
  - Symptom: inconsistent logs/cert/debug timestamps between nominally same release family.
- **Recommended fix (exact snippet):**
```diff
# preseed/preseed-ubuntu.cfg
- d-i time/zone string America/New_York
+ d-i time/zone string UTC
```
(or make timezone an explicit operator prompt in both flows)
- **Risk / effort:** Medium UX risk, low effort.

---

## Low Findings

### 11) NoMachine URL is hardcoded without integrity verification
- **File refs:** `post-install/31-remote-access.sh`
- **What is wrong / symptom:**
  - Pulls remote `.deb` from fixed URL without checksum/signature verification.
  - Symptom: fragile install path and supply-chain trust gap.
- **Recommended fix (exact snippet):**
```diff
+ NM_SHA256="<published hash>"
+ echo "${NM_SHA256}  /tmp/nomachine.deb" | sha256sum -c - || { echo "checksum mismatch"; exit 1; }
```
- **Risk / effort:** Low-medium risk, low effort.

### 12) Wallpaper rotator daemon has no single-instance guard
- **File refs:** `post-install/45-wallpaper-rotator.sh`
- **What is wrong / symptom:**
  - Autostarted daemon loops forever; no lockfile/pgrep guard.
  - Symptom: duplicate daemons possible in multi-session/restart edge cases.
- **Recommended fix (exact snippet):**
```diff
# /usr/local/bin/ncz-wallpaper-daemon
+ LOCK="${XDG_RUNTIME_DIR:-/tmp}/ncz-wallpaper-daemon.lock"
+ [ -e "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null && exit 0
+ echo $$ > "$LOCK"
+ trap 'rm -f "$LOCK"' EXIT
```
- **Risk / effort:** Low risk, low effort.

---

## Nit Findings

### 13) Hook identity/log prefix mismatch
- **File refs:** `post-install/45-wallpaper-rotator.sh`
- **What is wrong / symptom:** Script name is `45-*` but logs with `[55]`, which complicates correlating hook logs quickly.
- **Recommended fix:** Align the printed prefix to hook number or a stable tag name.
- **Risk / effort:** Very low risk, trivial effort.

### 14) Several comments/documentation strings are stale after architecture changes
- **File refs:** multiple comments in desktop/preseed hooks (e.g., references to prior GNOME defaults or historical package assumptions)
- **What is wrong / symptom:** Not functionally wrong, but increases maintenance friction and review ambiguity.
- **Recommended fix:** Sweep comments for current-state-only notes and move historical narrative to docs.
- **Risk / effort:** Very low risk, low effort.

---

## Quick Wins (Low-Risk, High-Impact)

1. Disable default diagnostic account + static diagnostics passwords by default build profile.
2. Tighten SSH defaults to key-only root (`prohibit-password`) and disable password auth.
3. Fix `20-desktop.sh` launcher copy to use a guaranteed staged source (or remove if deprecated).
4. Add browser fallback logic so `chromium-browser` compatibility never points to a missing binary.
5. Remove `preseed/late.sh.patch` and `preseed/late.sh.rej` from payload and add ignore patterns.

## Needs Discussion / Subjective

1. Hostname policy: keep deterministic `ncz-<mac8>` (fleet-unique) vs preserving `mini` for friendliness.
2. Appliance lock-screen policy: default unlocked kiosk-like UX vs secure auto-lock defaults.
3. Whether Cix proprietary stack failures should hard-stop install or remain soft-fail with prominent post-boot warning banner.
4. Whether NoMachine should be default-on dependency or optional operator-installed path to reduce external download coupling.

EOF' "$BROWSER_BIN" "$@"
```
- **Risk / effort:** Medium-high risk, low-medium effort.

### 5) NetworkManager correctness is optional-phase only despite being connectivity-critical
- **File refs:** `post-install/33-network.sh`, `post-install/run-all.sh`
- **What is wrong / symptom:**
  - `33-network.sh` hard-fails if `network-manager` missing, but Phase 2 treats all such failures as non-fatal.
  - Install can complete with no guaranteed first-boot network if this hook fails.
- **Recommended fix (exact snippet):**
```diff
# post-install/run-all.sh (required list)
- 10-our-kernel.sh|12-sky1-firmware.sh)
+ 10-our-kernel.sh|12-sky1-firmware.sh|33-network.sh)
```
_or add a Phase 1.5 for required post-network hooks._
- **Risk / effort:** High operational risk, low-medium effort.

### 6) DPMS/screen lock policy conflicts between Xorg and xscreensaver
- **File refs:** `post-install/22-display-fix.sh`, `post-install/20-desktop.sh`
- **What is wrong / symptom:**
  - Xorg config disables DPMS/blanking at server level.
  - Default `~/.xscreensaver` enables DPMS and lock after 10 min.
  - Appliance behavior becomes inconsistent across displays/sessions (unexpected lock/blank or no-op depending on path).
- **Recommended fix (exact snippet):**
```diff
# choose one policy for appliance default (example: no auto-lock)
# post-install/20-desktop.sh in .xscreensaver template
- lock:           True
- dpmsEnabled:    True
+ lock:           False
+ dpmsEnabled:    False
```
_and document secure mode as an explicit operator toggle._
- **Risk / effort:** Medium risk, low effort.

---

## Medium Findings

### 7) `50-brand.sh` appears truncated and logs non-existent greeter branding variables
- **File refs:** `post-install/50-brand.sh`
- **What is wrong / symptom:**
  - Script now writes textual OS identity (`os-release`, `issue`, `motd`) but ends with:
    `echo "[50] LightDM greeter rebranded — bg=$NCZ_GREETER_BG, user-img=$NCZ_USER_IMG"`
  - Variables are never defined in this script; no greeter/user image branding occurs here.
  - Symptom: misleading logs and unclear ownership of visual branding behavior.
- **Recommended fix (exact snippet):**
```diff
# post-install/50-brand.sh
- echo "[50] LightDM greeter rebranded — bg=$NCZ_GREETER_BG, user-img=$NCZ_USER_IMG"
+ echo "[50] text branding applied (os-release/issue/motd)"
```
_or actually implement greeter branding in this hook and define those vars._
- **Risk / effort:** Low-medium risk, low effort.

### 8) Chroot-time `systemctl enable --now ... || true` patterns hide service activation mistakes
- **File refs:** e.g. `post-install/20-desktop.sh` (`ncx-upstream-watch.timer`)
- **What is wrong / symptom:**
  - `--now` in chroot is fragile; failures are ignored.
  - Depending on unit/systemctl behavior, enablement may not be guaranteed and logs become noisy.
- **Recommended fix (exact snippet):**
```diff
- systemctl enable --now ncx-upstream-watch.timer 2>&1 | tail -2 || true
+ systemctl enable ncx-upstream-watch.timer 2>&1 | tail -2
+ systemctl start ncx-upstream-watch.timer 2>&1 | tail -2 || true
```
- **Risk / effort:** Medium risk, low effort.

### 9) Shipping `.patch`/`.rej` artifacts in preseed payload is a release hygiene and trust issue
- **File refs:** `preseed/late.sh.patch`, `preseed/late.sh.rej`
- **What is wrong / symptom:**
  - Installer payload includes conflict residue files.
  - Symptom: operator confusion, uncertainty about whether live script reflects intended patch; avoidable footprint noise.
- **Recommended fix (exact snippet):**
```diff
# remove from tree
- preseed/late.sh.patch
- preseed/late.sh.rej
```
```diff
# .gitignore
+ *.rej
+ *.orig
+ *.patch
```
- **Risk / effort:** Low operational risk, very low effort.

### 10) Timezone defaults diverge by preseed path
- **File refs:** `preseed/preseed.cfg` (UTC), `preseed/preseed-ubuntu.cfg` (America/New_York)
- **What is wrong / symptom:**
  - Different installer paths produce different default timezone behavior.
  - Symptom: inconsistent logs/cert/debug timestamps between nominally same release family.
- **Recommended fix (exact snippet):**
```diff
# preseed/preseed-ubuntu.cfg
- d-i time/zone string America/New_York
+ d-i time/zone string UTC
```
(or make timezone an explicit operator prompt in both flows)
- **Risk / effort:** Medium UX risk, low effort.

---

## Low Findings

### 11) NoMachine URL is hardcoded without integrity verification
- **File refs:** `post-install/31-remote-access.sh`
- **What is wrong / symptom:**
  - Pulls remote `.deb` from fixed URL without checksum/signature verification.
  - Symptom: fragile install path and supply-chain trust gap.
- **Recommended fix (exact snippet):**
```diff
+ NM_SHA256="<published hash>"
+ echo "${NM_SHA256}  /tmp/nomachine.deb" | sha256sum -c - || { echo "checksum mismatch"; exit 1; }
```
- **Risk / effort:** Low-medium risk, low effort.

### 12) Wallpaper rotator daemon has no single-instance guard
- **File refs:** `post-install/45-wallpaper-rotator.sh`
- **What is wrong / symptom:**
  - Autostarted daemon loops forever; no lockfile/pgrep guard.
  - Symptom: duplicate daemons possible in multi-session/restart edge cases.
- **Recommended fix (exact snippet):**
```diff
# /usr/local/bin/ncz-wallpaper-daemon
+ LOCK="${XDG_RUNTIME_DIR:-/tmp}/ncz-wallpaper-daemon.lock"
+ [ -e "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null && exit 0
+ echo $$ > "$LOCK"
+ trap rm -f  EXIT
```
- **Risk / effort:** Low risk, low effort.

---

## Nit Findings

### 13) Hook identity/log prefix mismatch
- **File refs:** `post-install/45-wallpaper-rotator.sh`
- **What is wrong / symptom:** Script name is `45-*` but logs with `[55]`, which complicates correlating hook logs quickly.
- **Recommended fix:** Align the printed prefix to hook number or a stable tag name.
- **Risk / effort:** Very low risk, trivial effort.

### 14) Several comments/documentation strings are stale after architecture changes
- **File refs:** multiple comments in desktop/preseed hooks (e.g., references to prior GNOME defaults or historical package assumptions)
- **What is wrong / symptom:** Not functionally wrong, but increases maintenance friction and review ambiguity.
- **Recommended fix:** Sweep comments for current-state-only notes and move historical narrative to docs.
- **Risk / effort:** Very low risk, low effort.

---

## Quick Wins (Low-Risk, High-Impact)

1. Disable default diagnostic account + static diagnostics passwords by default build profile.
2. Tighten SSH defaults to key-only root (`prohibit-password`) and disable password auth.
3. Fix `20-desktop.sh` launcher copy to use a guaranteed staged source (or remove if deprecated).
4. Add browser fallback logic so `chromium-browser` compatibility never points to a missing binary.
5. Remove `preseed/late.sh.patch` and `preseed/late.sh.rej` from payload and add ignore patterns.

## Needs Discussion / Subjective

1. Hostname policy: keep deterministic `ncz-<mac8>` (fleet-unique) vs preserving `mini` for friendliness.
2. Appliance lock-screen policy: default unlocked kiosk-like UX vs secure auto-lock defaults.
3. Whether Cix proprietary stack failures should hard-stop install or remain soft-fail with prominent post-boot warning banner.
4. Whether NoMachine should be default-on dependency or optional operator-installed path to reduce external download coupling.

