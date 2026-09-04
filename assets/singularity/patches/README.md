# Singularity Desktop downstream patches

Patches carried against `singularityos-lab/singularity-desktop` (and its
bundled `labwc`/`wlroots` subprojects) for NCZ-OS on CIX Sky1.

`build/build-singularity.sh` runs `scripts/apply-downstream-patches.sh` from
the upstream tree when that script is present. It is NOT present in
`master` as of 2026-09-04, so these patches are currently applied by hand
before `meson setup`:

    cd singularity-desktop/subprojects/labwc
    git apply /path/to/assets/singularity/patches/0001-*.patch

## 0001 — labwc: re-enable an output on a backend mode request

**Fixes:** HDMI/DP replug leaves the screen black until the compositor is
restarted (`systemctl restart greetd` was the standing workaround).

`handle_output_request_state()` has a fast path for the case where the
backend reports that ONLY the mode changed: it stages the new mode into
`output->pending` and schedules a frame. A DP/HDMI replug arrives through
exactly that path while the output is still disabled from the unplug.

Staging a mode on a disabled output makes wlroots reject the ENTIRE atomic
state in `output_basic_test()`:

    Tried to set mode on a disabled output
    (wlroots types/output/output.c)

so the commit fails as a whole and the output is never re-enabled —
`enabled=disabled`, `dpms=Off`.

The kernel was ruled out before this patch was written: kretprobes on
`linlondp_kms_check`, `linlondp_build_display_data_flow` and
`linlondp_release_unclaimed_resources` all returned 0, and
`output_basic_test()` returns before any DRM ioctl is issued. It reproduces
on both O6N (one output) and MS-R1 (four outputs), so it is not a
multi-head-topology bug either.

### Why it enables only as a fallback

A blanked screen (wlr-output-power-management, DPMS off) is *also* a
disabled output, and `wlr_output->enabled` is identical in both cases.
Unconditionally enabling here would turn the display back on every time the
backend reported a mode, defeating screen blanking.

So the patch adds `output->power_off` to record the intent explicitly, set
in `handle_output_power_manager_set_mode()`, and only enables when:

  - the output was not deliberately powered off, AND
  - it is currently disabled, AND
  - the mode-only state does not already test clean

If enabling still does not test clean, BOTH the `ENABLED` and `MODE` bits are
dropped from the pending state — staging `enabled=false` with the mode still
present would rebuild the same invalid combination and poison the next commit
for an unrelated reason.

### Status

**NOT YET VERIFIED ON HARDWARE.** It requires a full singularity-desktop
rebuild (Vala/GTK4 plus the bundled labwc/wlroots) and then a physical
unplug/replug on a board. The check is that the display returns on replug
with no `systemctl restart greetd`, and — equally important — that screen
blanking still blanks and stays blanked.
