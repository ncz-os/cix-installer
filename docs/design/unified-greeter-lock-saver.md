# Unified NCZ greeter + lockscreen + screensaver — design and recommendation

**Status:** design phase only. No merges, no PRs, no upstream contact.
**Date:** 2026-10-11
**Author:** Jason Perlow (design/analysis). AI-assisted; upstream-facing text will carry the
`Assisted-by:` / `AI-Scope:` trailers when it becomes a commit.
**Scope:** an NCZ-specific greeter + lock + screensaver system, designed so the same
architecture can be offered upstream to Singularity (Mirko Brombin) *if he wants it*.
**Gate respected:** nothing here is a PR. Upstream contact happens only after images ship and
the 72 h soak, and only as small, optional, one-concern changes.

---

## 0. Sources read (real code, cited)

Upstream/clone source reviewed for this document:

- **Lockscreen** — `singularity-shell`, `src/lockscreen/` (local fork clone `aa840df`, 2026-09-25):
  `lock_main.c` (604 lines), `pam_auth.c` (103), `lock_surface.c/.h/.vapi`, `lock_screen.vala`
  (301), `meson.build` (42), `dev.sinty.lockscreen.gschema.xml`.
- **Greeter** — `singularity-greeter`, `greeter_main.c` (924 lines; working copy at
  `~/.codex-tmp/greeter_main.c`, upstream pin `ddb9ac60`). Same repo referenced by the
  `singularity-desktop` submodule gitlink.
- **Screensaver** — `ncz-screensavers` (`/mnt/datapool/git/ncz-screensavers.git`):
  `include/wlscreensaver.h` (170), `launcher/ncz-screensaver-idled.c` (>1401),
  `launcher/ncz-screensaver` (`session_locked()` :1953, refusal :2213), `launcher/ncz-screensaver-run-compat`,
  `config/dev.ncz.screensaver.gschema.xml`, `docs/LAUNCHER-DESIGN.md` (230), `meson.build`.
- **Image integration** — `cix-installer`: `post-install/55-greeter.sh` (greetd config,
  `ncz-has-drm-output`, `ncz-wait-input-ready`, greeter-labwc autostart, `_greetd` expiry),
  `post-install/20-desktop.sh` (`ncz-singularity-greeter` wrapper :956+, `ncz-gpu-env` :568+),
  `assets/display/ncz-display-scale`.
- **Prior design** — `singularity-shell` `docs/superpowers/specs/2026-09-25-screensaver-preferences-design.md`.
- **MNEMOS rulings/prior art** — `mem_1787011786639_f7c83f` ("the lockscreen is the
  screensaver", operator-approved 2026-08-17), `mem_1786989250745_fc4438` (dual-surface
  lock architecture agreed with Mirko), `mem_1786918906851_a51ce3` (lock is exclusive; a
  dead lock client wedges labwc locked → black screen; never kill it), sslock
  `ORCH-EVIDENCE.md` (measured 300 s race on PEGASUS/PROTEUS).
- **Contribution rules** — `~/.claude/rules-archive/singularity-contribution-guidelines.md`
  (11 rules) and `feedback_singularity_ai_attribution_format` / `feedback_attribution_by_destination`.

**Stated assumptions (not verified against a running image in this design-only session):**

1. The greeter source used is the `~/.codex-tmp/greeter_main.c` copy (upstream pin `ddb9ac60`,
   2026-10-06). It was not available on GitLab `ncz-os` or ARGONAS as a standalone repo — only the
   `singularity-desktop` umbrella mirror is. The conclusions below do not depend on greeter internals
   that could have changed; they depend on its *shape* (layer-shell client under greetd's labwc).
2. The **shipped** Singularity shell is newer than the local fork clone (`aa840df`, 2026-09-25).
   Binary strings from the live host (`recon2/recon3`) show an `IdleManager`, an
   `org.freedesktop.ScreenSaver` / `SingularityScreenSaverService` D-Bus surface, and a
   fingerprint-capable lockscreen that are **not** in the local tree. The 2026-09-25 design doc is
   therefore partially superseded: upstream already grew idle/lock plumbing.
3. All three clients already render through the same `loginui` Cairo library, so "unified" is a
   control-plane and surface-hosting question, not a re-skin.

---

## 1. Requirements

### 1.1 Functional

| # | Requirement | Notes / where it lives today |
|---|---|---|
| F1 | **Login**: list users, per-user avatar/background, session chooser, auth, hand off to the session | `greeter_main.c`; talks greetd JSON (`create_session` → `auth_message` → `post_auth_message_response` → `success` → `start_session` → exit) |
| F2 | **Lock**: a real `ext-session-lock-v1` client, compositor-enforced, cannot be dismissed by a stray key reaching the desktop | `lock_main.c` (`lock_main.c:543` `ext_session_lock_manager_v1_lock`) |
| F3 | **Idle ordering**: `idle → saver → (later) lock`, deterministic, on every image | Today two independent timers both fire at 300 s: shell `dev.sinty.lockscreen idle-delay=300` and `dev.ncz.screensaver hack-idle-delay=300` |
| F4 | **Saver overrides the lock surface with input-dismiss to unlock prompt** (operator 2026-10-11, decisive) | Not achievable as designed: `ext-session-lock-v1` is exclusive, and a separate process' layer-shell surface cannot composite over it |
| F5 | **Multi-output**: greeter, lock and saver each cover every output; hotplug (output add/remove) handled | greeter `greeter_main.c:818-825,886`; lock `lock_main.c:482-491,492-506`; saver binds **one** output (LAUNCHER-DESIGN.md:129 open item) |
| F6 | **Multi-GPU / card selection**: correct DRM device and GL vendor on every SKU (Mali blob, Panthor/Mesa, AMD, Intel+NVIDIA hybrid) | `ncz-gpu-env` (`NCZ_GPU_BACKEND`), `ncz-wlr-connected-drm` builds `WLR_DRM_DEVICES` from cards with a connected output; saver imports compositor GPU env from `/proc/<pid>/environ` |
| F7 | **Suspend/resume**: lock on suspend, saver suspended, displays restored | `ncz-screensaver-idled.c` logind `PrepareForSleep` + `lock-on-suspend`; `zwlr_output_power` |
| F8 | **Fast user switch**: lock session A, allow session B; on return, A is still locked | Needs logind session Lock/Unlock + per-seat state; not solved today |
| F9 | **Fingerprint / PAM**: PAM unlock, optional fingerprint, PIN path on SintyOS | `pam_auth.c` (PAM + `sinty-recoverd` verify); shipped lock adds fingerprint ("fingerprint verification unavailable" string on the live host) |
| F10 | **Accessibility**: on-screen keyboard reachable, visible focus, screen reader can reach the prompt | Neither client implements an OSK today; no a11y tree in either raw client |
| F11 | **First-boot / black-screen feedback**: never a black screen with no login/lock affordance; a slow display link must not look like a hang | greeter waits for a connected DRM output (`ncz-has-drm-output`, ≤30 s) and a settled input device (`ncz-wait-input-ready`); `ncz-display-scale greeter` caps the login mode |
| F12 | **Failed-auth recovery**: wrong credential returns to a usable prompt; never a stuck "Authenticating…"; never a swallowed error | lock `lock_main.c:347-352`; greeter `greeter_main.c:431-441` (`error` → `cancel_session`) |
| F13 | **Fail-closed lock**: crash of the saver/engine must **not** unlock; crash of the lock client must not leave a permanent black screen | Ruling `mem_1787011786639_f7c83f`; `wlscreensaver.h:139-162`; idled relock loop `ncz-screensaver-idled.c:417-444` |
| F14 | **Input dismissal is universal**: any seat input dismisses the saver (key, pointer, touch), independent of the hack handling input | `ext-idle-notification.resumed` (LAUNCHER-DESIGN.md:57-64) |
| F15 | **Fingerprint/PAM prompt in the lock, not in the desktop** (desktop must not leak behind lock) | lock surface covers outputs; desktop never drawn |

### 1.2 Non-functional

- **N1 Security / fail-closed** prevails over every visual requirement. The auth path must be
  unreachable from the renderer (no shared heap with a crashed hack). A dead renderer degrades
  to a static background; a dead locker must be re-taken.
- **N2 Latency**: idle→first saver frame and idle→lock prompt must be bounded (target < 1 s on
  the hosts we ship), no multi-second black gap.
- **N3 Power**: DPMS-off is independent of the saver and lock; any input restores all outputs.
- **N4 Determinism**: exactly one owner of the lock per session; exactly one saver per output.
- **N5 Testability**: the whole chain must be exercisable headless (labwc + KVM) with a virtual
  input client, and on the real-hardware matrix.
- **N6 Upstreamability** (a constraint, not a goal): any code offered upstream must be small,
  optional, behind a flag/interface, distro-neutral, no NCZ names/paths/branding.

### 1.3 Non-requirements (explicitly out of scope)

- Porting or wrapping xscreensaver / Xwayland / the xscreensaver daemon (already decided:
  native engine only).
- Building GPU fidelity tiers / the settings UI (owned elsewhere).
- Changing greetd's session model, PAM policy, or the boot splash.
- A GTK/GNOME-style end-to-end rewrite; the clients stay raw Wayland + loginui.
- Shipping anything to upstream in this phase.

---

## 2. What the pieces actually are (the constraints that force the design)

1. **`ext-session-lock-v1` is exclusive by protocol.** While locked, the compositor presents the
   lock surface and nothing else; a separate process' `wlr-layer-shell` overlay (even OVERLAY)
   is invisible, and Wayland subsurfaces must come from the same `wl_client`. This is *measured*,
   not assumed (`mem_1787011786639_f7c83f`): every screenshot during a lock showed the lock UI
   while the saver ran underneath. **Consequence: F4 ("saver over lock") cannot be met by adding
   a second process; the saver must render inside the lock client.**
2. **Both existing clients are thin raw-Wayland clients over the same `loginui` Cairo renderer.**
   Greeter: layer-shell OVERLAY, exclusive keyboard, one surface per output
   (`greeter_main.c:755-768, 818-825, 886`). Lock: `ext-session-lock-v1`, one lock surface per
   output, Cairo + PAM (`lock_main.c:296-317, 482-506, 543`). The greeter even has a Vala
   layer-shell **fallback** lock (`lock_screen.vala:68-76,131-136`) alongside the C locker.
3. **A dead lock client wedges the compositor.** labwc keeps `locked = true` with no client →
   permanent black screen, recovery only by reboot (`mem_1786918906851_a51ce3`; idled's relock
   loop `ncz-screensaver-idled.c:417-444` is the mitigation). This is the single largest risk to
   the whole "host the renderer in the locker" direction, and the reason `wlscreensaver.h` exists.
4. **The engine is already written to be embedded.** `include/wlscreensaver.h` is a MIT library
   whose documented purpose is exactly this: a *host* (lock screen / saver daemon / preview)
   owns the Wayland connection and surface; the engine owns EGL + the effect and "nothing else";
   it explicitly enumerates the fail-closed contract (`wlscreensaver.h:1-27, 139-162`). The
   compositor/surface-role split is the *branch point* — the same engine attaches to a
   `wlr_layer_surface_v1` or an `ext_session_lock_surface_v1`.
5. **There is already a control plane in pieces**: shell `IdleManager` + `org.freedesktop.ScreenSaver`
   (shipped, strings), `dev.sinty.lockscreen` (lock keys), `dev.ncz.screensaver` (saver keys) and
   a `ncz-screensaver-idled` daemon that also drives the lock (`ncz-screensaver-idled.c:446-503`).
   Two lock owners coexist today, which is the P0 bug.
6. **`greetd` hands off by the greeter exiting.** `-S singularity-greeter` makes the greeter
   compositor exit on success; the wrapper deliberately does not round-trip before exit
   (`greeter_main.c:914-923`). Keeping the greeter alive as the "system UI" (option D) fights this.

---

## 3. Architecture options and trade-offs

### Option A — keep upstream greeter + lock, ship an NCZ patch set

Stay on the upstream `singularity-greeter` and `singularity-lockscreen` binaries; carry all NCZ
behaviour as a downstream patch overlay (`/ncz-patches/singularity-shell/*.patch`, applied by
`build-singularity.sh`), as we do today.

| Axis | Assessment |
|---|---|
| `ext-session-lock-v1` exclusivity | Respected but **unsolved**: still no path for F4 without patching `lock_main.c`, which then *is* option B in disguise |
| GPU-context ownership | Unchanged (separate processes) |
| Security / fail-closed | Today's behaviour; the relock loop covers a dead locker |
| Complexity | Lowest new code; highest maintenance |
| Upstreamability | **Worst.** Mirko wants small optional changes and one concern per PR (rule 3); a drift-prone overlay is exactly the patch-rot pattern we already had to fix once |
| Test strategy | Existing harness |
| Rollout | Fast |

**Verdict:** acceptable only as the P0 interim, not as the end state.

### Option B — one NCZ session-lock client that hosts the saver renderer (the lockscreen IS the saver)

The lock client owns the `ext-session-lock-v1` surface and **embeds the GLES engine** via
`wlscreensaver.h`, rendering the chosen hack into the lock surface; the prompt composits on top
(or appears on first input). This is the literal form of ruling `mem_1787011786639_f7c83f` and
the dual-surface decision agreed with Mirko (`mem_1786989250745_fc4438`).

Two sub-shapes, per the ruling:
- **B1 in-process + hard fail-closed watchdog** — engine runs in the lock client; a crash/hang
  falls back instantly to the static wallpaper, prompt stays live (`wlscreensaver.h:139-162`).
- **B2 separate renderer process composited by the compositor** — strongest isolation, but it
  needs either a second surface from the *same* `wl_client` (i.e. a child of the lock client) or
  a compositor feature that does not exist. B2 is the target only where the compositor allows.

| Axis | Assessment |
|---|---|
| `ext-session-lock-v1` exclusivity | **The only shape that satisfies it** — one lock client, one `wl_client`, saver pixels come from it |
| GPU-context ownership | Engine owns EGL + GL context; host owns `wl_display` + surface + shell role (`wlscreensaver.h:63-133`). GL init must happen after the lock surface exists and per-output scale is known |
| Security / fail-closed | Strongest: prompt in code the engine cannot reach; false `wlss_frame()` → drop engine, keep prompt; bounded frame time (`wlss_watchdog_ms`). Failure containment is a *documented requirement*, not a nicety |
| Complexity | Highest: EGL/GLES inside a Cairo client, per-output GL surfaces, GPU vendor selection inside the lock process, watchdogs |
| Upstreamability | **Good if framed as the optional interface it already is**: lock client gains a build-flagged "renderer hook" (`-Dlock_renderer=...`) that loads an engine; defaults off; generic, no NCZ branding. `wlscreensaver.h` is MIT and explicitly written "for Mirko" |
| Test strategy | The engine API is headless-testable; host-level watchdog and lock lifetime need the KVM gate plus the real matrix |
| Rollout | Larger; must ship behind a flag so the default locker is unchanged |

**Verdict:** the correct rendering architecture for F4 + F13; the engine API is already the right
seam.

### Option C — small shared library + IPC protocol spanning greeter, lock and saver

Formalise the shared `loginui` renderer and a control plane: a shared surface-hosting/state
library plus a D-Bus contract so greeter, lock and saver coordinate idle, lock, output list and
"saver running/stopped". The shell already exports `org.freedesktop.ScreenSaver`; a generic
`org.freedesktop`-style or `singular.Session` interface is a natural home (rule 2: no `ncz` names).

| Axis | Assessment |
|---|---|
| Exclusivity | **Does not solve it alone** — coordination cannot move saver pixels over an exclusive lock surface |
| GPU context | No direct help; the renderer location is decided by B |
| Security | Neutral; can *reduce* risk by removing the two-lock-owner race |
| Complexity | Moderate; but D-Bus adds a failure surface (order, restarts, stale names) |
| Upstreamability | Good **if** the interface is generic and each change is one concern |
| Test strategy | D-Bus is easy to unit-test headless |
| Rollout | Can land before B |

**Verdict:** complementary, not an alternative. C is the correct **control plane**; B is the
correct **render plane**. C alone fixes F3/F7/F8 and the two-owner race; B is still required for F4.

### Option D — greetd-only: greeter = lockscreen = saver host, logind lock signals

Treat the greeter compositor as the session's persistent system UI; the lock is the greeter
re-shown; the saver is hosted there; `logind` `Lock`/`Unlock` drive state.

| Axis | Assessment |
|---|---|
| Exclusivity | Sidestepped (the system UI owns the screen both times) |
| GPU context | Single renderer, single EGL bring-up |
| Security | **Bad fit**: keeping the greeter session alive means running the user session inside the greeter's trust boundary, or a custom hand-off greetd does not model |
| Complexity | Very high: changes greetd's session model and the desktop session lifecycle |
| Upstreamability | **Poor**: greetd is not ours to redesign; a large architectural change will be rejected |
| Test strategy | Hard (needs greetd internals) |
| Rollout | Not incremental |

**Verdict:** rejected. Elegant in the abstract, but it fights greetd's contract
(`greeter_main.c:914-923`) and is not upstreamable.

### Summary matrix

| | A patch set | B lock hosts engine | C shared lib/IPC | D greetd-only |
|---|---|---|---|---|
| Solves F4 (saver over lock) | ✗ (becomes B) | **✓** | ✗ alone | ✓ |
| Solves F3 two-owner race | partial | partial | **✓** | ✓ |
| Fail-closed lock (F13) | today's relock | **strongest** | neutral | ok |
| GPU-context clarity | separate procs | engine owns EGL | n/a | single renderer |
| Complexity | low code / high rot | **highest** | moderate | very high |
| Upstreamable | ✗ | **✓ (optional hook)** | ✓ (generic iface) | ✗ |
| Headless-testable | yes | engine yes; host KVM | yes | hard |
| Incremental rollout | yes | behind flag | yes | no |

---

## 4. Recommendation

**Adopt B + C, use A only as the P0 interim, reject D.**

- **Render plane = B**, standardised on the already-written `wlscreensaver.h` contract. The lock
  client becomes the sole `ext-session-lock-v1` owner and the sole host of the saver renderer,
  with an in-process engine and a hard fail-closed watchdog (B1) as the first ship; B2 is the
  target only if a compositor path appears.
- **Control plane = C**, minimal: one idle owner, one lock owner, one output/power owner, exposed
  through a generic D-Bus/state contract (reuse the existing `org.freedesktop.ScreenSaver` the
  shell already speaks; do **not** invent an `ncz.*` name upstream).
- **A** is only the P0 bridge until B+C ship, and only because the operator's interim must land
  on all images now.
- **D** is documented and rejected so it is not re-derived.

### Phases

| Phase | Goal | Work | Exit criteria | Effort |
|---|---|---|---|---|
| **P0 — interim (sslock)** | Saver wins the idle event; timer works on **all** images, both arches | Smallest NCZ-specific change: one idle owner / strict `lock-delay > saver-delay`, **and** the operator's "saver over lock" where the lock client can host/launch it. Keep interfaces replaceable | Real 300 s timer proven on PEGASUS/PROTEUS, unlocked **and** locked; saver never refused "session is locked; not starting"; O6N/.66 covered | in flight elsewhere |
| **P1 — one control plane (C)** | Remove the two-lock-owner race: one idle owner, deterministic F3, fast-user-switch + suspend covered | Consolidate idle/lock/DPMS ownership; define a generic session/idle contract; keep greeter/lock binaries upstream-clean; NCZ behaviour via config, not patch | headless-labwc KVM gate green; no double lock; suspend/resume + FUS tested; no NCZ strings in shared code | ~1–2 PRs, 3–6 days |
| **P2 — render plane (B)** | F4: the saver renders *inside* the lock surface | Lock client gains a build-flagged renderer hook (`wlscreensaver.h`); in-process engine + fail-closed watchdog + static fallback; per-output GL surface; GPU/env selection inside the lock process | Saver visible while locked; any input → prompt; killing/hanging the engine never unlocks and never blanks the prompt; shipped behind an off-by-default flag | ~3–5 PRs, 1.5–3 wk incl. matrix |
| **P3 — upstream track** | Offer the small optional pieces to Mirko, one concern each | (a) the lock-client renderer hook (default off); (b) the idle/lock single-owner fix; (c) possibly `wlscreensaver.h` as a standalone library. Each small, generic, ASCII, near-zero comments | images shipped + 72 h soak; RFC answered; PRs opened small | per PR, 0.5–2 days + review |
| **P4 — retire patches** | After any merge, rebuild both arches and no-op superseded `/ncz-patches/` overlays | Rule 11 procedure | build green both arches, behaviour preserved | 0.5–1 day per merge |

### Risks

1. **Fail-open on engine crash (highest).** A hack is third-party C; a crash inside the lock
   process can expose the desktop or blank the prompt. Mitigation: B1 watchdog + static fallback +
   prompt isolated from the engine; ship behind a flag until the KVM + matrix prove containment.
2. **Compositor locked-wedge.** A dead lock client leaves labwc locked with no client → reboot.
   Mitigation: idled relock loop (already present) + never kill a lock client; documented recovery.
3. **Patch rot.** An NCZ overlay drifts from upstream and silently stops applying (already
   happened once). Mitigation: keep P0 patch minimal and retire it when P1/P2 land upstream.
4. **GPU/vendor regressions.** Embedding EGL in the lock process must reproduce Mali blob,
   Panthor/Mesa, AMD and hybrid iGPU+dGPU behaviour that today lives in `ncz-gpu-env` /
   `ncz-wlr-connected-drm`. Mitigation: reuse the exact env selection; test per-vendor.
5. **HiDPI / wrong resolution** if logical size and output scale are conflated (explicitly warned
   in `wlscreensaver.h:70-92`; the panel can be 4K while a session surface is 2194×1234).
6. **Multi-output** saver still binds one output (LAUNCHER-DESIGN.md:129); B must render per lock
   surface or F5 is unmet.
7. **Upstream scope rejection** if offered too large; mitigation: one concern per PR, optional,
   default-off, no branding.
8. **Greeter-specific bugs** (retry `create_session` after failed login → "a session is already
   being configured"; `wl_seat_get_keyboard` called without checking seat capabilities) are real
   upstream defects; fix small and separately, not bundled into this design.

### Open questions for the operator (decisions, not blockers)

1. **Push target:** `cix-installer` vs `ncz-screensavers` for the canonical copy of this design
   (this doc is pushed to `cix-installer`; cross-link from `ncz-screensavers`?).
2. **P0 scope:** does the interim land as (i) ordering only (`lock-delay > saver-delay`), (ii) the
   minimal "lock hosts/launches saver", or (iii) both? The design assumes both are acceptable and
   P0 chooses the least invasive that satisfies "the saver must never be refused".
3. **Default lock owner after P1:** the shell (`dev.sinty.lockscreen`) or `ncz-screensaver-idled`
   (`dev.ncz.screensaver`)? Recommendation: one owner, shell keeps the settings row, daemon obeys.
4. **Fingerprint in the lock:** the shipped lock already exposes fingerprint strings; confirm it is
   in scope for the unified lock and where the sensor is claimed (greeter vs lock).
5. **Upstream appetite:** do we open the RFC *before* P2 code exists (design-first, cheap) or only
   after images + soak per the standing rule? Recommendation: RFC after soak, referencing shipped
   evidence.
6. **Multi-output saver:** is per-output hack instances required for launch, or is "saver on the
   primary output + DPMS all outputs" acceptable for v1?

---

## 5. What to ask upstream first (RFC issue draft — short)

> **Proposed `singularityos-lab/singularity-shell` issue (draft; not filed):**
>
> **Title:** Session lock: optional renderer hook so a screensaver can draw on the lock surface
>
> While a session is locked, `ext-session-lock-v1` presents only the lock surface, so a separate
> screensaver process cannot draw. We already have a small MIT engine header
> (`wlscreensaver.h`: host owns `wl_display`+surface, engine owns EGL; fail-closed watchdog) and a
> native GLES screensaver. Would you accept an **optional, default-off** build flag in
> `singularity-lockscreen` that lets a host/library render into the existing lock surface, with the
> auth path untouched and a static fallback if the renderer fails? Generic, no distro-specific code.
> Happy to split it into small PRs or keep it downstream if you'd rather not carry it.

*(Attribution trailers to be added only when this becomes a commit/PR, per the contribution rules.)*

---

## 6. Appendix — key citations

- Lock exclusivity is protocol-forced: `mem_1787011786639_f7c83f`; `wlscreensaver.h:11-16, 139-162`.
- Lock client ownership and failure: `lock_main.c:296-325, 543-545`; `mem_1786918906851_a51ce3`.
- Greeter shape and hand-off: `greeter_main.c:755-768, 862-888, 914-923`.
- Idle/DPMS/lock daemon: `ncz-screensaver-idled.c:114-131, 278-294, 446-503, 1099-1152`.
- Saver refusal while locked: `launcher/ncz-screensaver:1953-1963, 2210-2213`.
- Engine contract: `include/wlscreensaver.h` (whole file).
- Launcher/idle design + open items: `docs/LAUNCHER-DESIGN.md:33-104, 118-144, 190-230`.
- Image integration: `post-install/55-greeter.sh` (greetd/labwc/display/input gates);
  `post-install/20-desktop.sh:956-1010` (greeter wrapper), `:568-790` (`ncz-gpu-env`).
- Contribution rules: `singularity-contribution-guidelines.md` §§0–11.
