# Proposal: forky-only base, no Ubuntu repository usage

Status: **PROPOSAL — not adopted.** This document changes no policy, no
source line and no gate. It records what Ubuntu usage exists in this tree
today, and what a "Debian forky only" end state would require. Adoption is a
separate, reviewed change.

Scope note: this file deliberately carries **no build-host, network or fleet
detail**. Host/network restrictions and the operational runbook for the base
mirror live in the private fleet-operations repository, never here.

## 1. The policy already in force

The rule "Debian forky only; Ubuntu debs never" is already implemented, not
aspirational:

| Mechanism | File | What it enforces |
|---|---|---|
| Offline Ubuntu-evidence gate | `build/check-no-ubuntu.sh` | No Ubuntu archive/PPA/container/default in the build+install sources; no Ubuntu-built ELF under `assets/`; any Ubuntu-built `.deb`/rootfs fails |
| Provenance gate | `build/forky-provenance.py`, `build/check-forky-provenance.sh` | Every package in a scanned tree must be NCZ, a reviewed vendor deb (pinned sha), or byte-identical to the pinned Debian forky snapshot |
| Builder guard | `build/lib/mirror-apt-opts.sh` (`ncz_require_debian_forky`) | Every rootfs/mirror builder refuses any suite other than `forky` and any mirror naming `ubuntu`/`launchpad`/`canonical` |
| Source allowlist | `manifests/vendor-repos.tsv` | Every apt source an image references must match a reviewed row exactly on `(scheme, host, path, suite)`; unapproved rows fail closed |
| Installed-system pin | `post-install/lib/apt-separation.sh` | A leaked Ubuntu build is pinned out; NCZ-owned names cannot be taken over by a non-NCZ origin |
| Positive/negative fixtures | `build/test-no-ubuntu.sh` | The Ubuntu-maintained `fonts-liberation 1:2.1.5-3build1` **must** fail; Debian's `1:2.1.5-3` **must** pass |

So the question is not "should we ban Ubuntu". It is: **where does Ubuntu still
appear, and can each remaining appearance be removed without losing function?**

## 2. Ubuntu usage found in the tree (evidence)

Four classes, in descending order of how much they actually matter.

### 2.1 A leaked Ubuntu deb (already neutralised)

`fonts-liberation 1:2.1.5-3build1` — an Ubuntu-maintained build that was once
published to the NCZ repository. Because `build1` sorts higher than Debian's
`1:2.1.5-3`, it would win a version contest. It is already:

* recorded in `ncz_apt_leaked_versions()` (`post-install/lib/apt-separation.sh`)
  and written to the pin file at priority `-1`, so it is never offered and is
  a one-time downgrade off a machine that installed it; and
* used as a **negative fixture** in `build/test-no-ubuntu.sh`.

Remediation: none required for correctness. The only follow-up is ensuring the
offending build is not merely pinned-out but absent from the registry (a
registry action, tracked in the private ops process), so a fresh machine never
has to un-install it.

### 2.2 Intel OpenVINO vendor repository — `suite` token `ubuntu24`

`manifests/vendor-repos.tsv`:

```
vendor  https  apt.repos.intel.com  /openvino  ubuntu24  yes  Intel  ...
```

The `ubuntu24` string is **Intel's own compatibility label** for the suite it
publishes the OpenVINO runtime under; the packages are Intel-authored, not
Ubuntu-authored. The provenance gate still hard-rejects any Ubuntu-maintained
or Ubuntu-versioned deb regardless of which host served it. This is a
**naming** smell, not an Ubuntu-dependency: the source cannot be dropped
without losing the OpenVINO runtime on amd64.

Proposed handling: keep the source, but make the row's `note` say explicitly
that `ubuntu24` is a vendor suite token and that the packages are
Intel-built — so a future reviewer does not read the row as an Ubuntu source.
(Already partly stated in the row note; see §4.)

### 2.3 t2linux `t2-ubuntu-repo` — genuinely Ubuntu-built packages

`manifests/vendor-repos.tsv`:

```
vendor  https  adityagarg8.github.io  /t2-ubuntu-repo  ./  yes  t2linux  ...
```

This is the only place where **Ubuntu-built binaries** are legitimately
consumed: the T2 firmware/audio/touchbar packages that only exist for Apple T2
hardware and are built by the t2linux project against Ubuntu. They are wired
at **first boot on real T2 Macs only** (`post-install/55-t2-firmware.sh`) and
are **never baked into the image**, so no shipped rootfs contains them. The
gate still rejects any Ubuntu-maintained deb *as a deb*, so these enter only
through the reviewed vendor allowlist, not as sneak-in Ubuntu userland.

This is the one class where "no Ubuntu at all" is not achievable without
losing T2 support. The honest options are:

* **(a) Accept as reviewed vendor exception** (status quo) — keep the row,
  document why, and require the packages to remain first-boot/real-hardware
  only. Lowest risk, no function lost.
* **(b) Rebuild the T2 set ourselves from t2linux's Debian-patchable sources**
  in a `debian:forky` container so the served debs are Debian-built. Highest
  fidelity to "forky only"; real effort, and only worth it if the T2 set is a
  release-critical surface.
* **(c) Vendor the built `.deb`s with pinned sha256** in the vendor ledger
  (`manifests/vendor-debs.tsv`), freezing them. Removes the live Ubuntu repo
  as an *update* source but freezes firmware updates.

Recommendation: **(a)** now, **(b)** if T2 grows into a first-class target.

### 2.4 Historical comments and unrelated matches (no action)

* `build/build-desktop-mirror.sh`, `build/build-baked-rootfs.sh`,
  `build/build-gtk4-layer-shell`, `README.md`, `README.zh-CN.md` mention
  Ubuntu only in *history* ("formerly this file's Ubuntu-Server closure",
  "the 2026-08-21 Ubuntu-era audit", the T2 upstream repo URL). Comments do
  not build anything; they are already excluded from the SRC gate as
  comment-only lines.
* `assets/refind/icons/README`, `assets/wallpaper/ocs-category-index.json`,
  `assets/models/bge-small-zh.../tokenizer.json` match the string "ubuntu" as
  **icon/wallpaper/model vocabulary**, e.g. a wallpaper category literally
  named "Ubuntu Touch" and a BPE token. These are data, not repositories, and
  must not be "cleaned" — scrubbing them would change shipped assets and model
  behaviour for no policy gain.

## 3. Proposed remediation plan (staged, non-binding)

Each stage is independently reviewable; **none is applied by this document.**

| Stage | Change | Risk | Function lost |
|---|---|---|---|
| 0 | Keep the policy gates exactly as they are (no change) | none | none |
| 1 | Clarify the OpenVINO row note: `ubuntu24` is Intel's suite token, packages are Intel-built | none | none |
| 2 | Add a doc pointer so `FORKY-ONLY` intent is discoverable from `docs/INDEX.md` | none | none |
| 3 | Confirm the `fonts-liberation 1:2.1.5-3build1` leak is removed from the registry, not just pinned | low | none |
| 4 | Decide the T2 set: vendor-with-pinned-sha (2.3c) or rebuild Debian-native (2.3b) | medium | fresh firmware updates (c) / effort (b) |
| 5 | Only if T2 is rebuilt: flip the row to the Debian-built staged debs and drop the live Ubuntu repo | medium | none, if the rebuild is equivalent |

Stage 4/5 are the *only* substantive policy decisions; everything before them
is documentation. This ordering means the tree can move toward "forky only"
without a flag day and without risking the amd64 OpenVINO path or T2 firmware.

## 4. Explicit non-goals

* **No change to `manifests/vendor-repos.tsv` approval state** in this
  proposal. The Intel and t2linux rows stay `approved=yes`.
* **No weakening** of `build/check-no-ubuntu.sh`,
  `build/forky-provenance.py`, or `ncz_require_debian_forky`.
* **No shipped-asset or model-vocabulary cleanup** (see §2.4).
* **No build-host, mirror-host or network detail** is recorded here; that is
  maintained in the private fleet-operations repository.

## 5. How to tell if the end state is reached

The end state ("no repository serving Ubuntu-built packages that we consume")
is verifiable without trusting prose:

* `bash build/check-no-ubuntu.sh` → `check-no-ubuntu: OK`;
* `bash build/test-no-ubuntu.sh` → `0 failed`;
* `manifests/vendor-repos.tsv` names **no** Ubuntu host as an active source;
  the remaining `ubuntu24` occurrence is only Intel's suite token; and
* the T2 set is served from NCZ-staged, Debian-built, sha-pinned debs rather
  than a live Ubuntu repo (stage 4/5).
