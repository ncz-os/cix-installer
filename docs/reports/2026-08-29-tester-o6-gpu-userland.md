# Second O6 report: no GPU acceleration, libMali absent

**Reporter:** tester "blood", 2026-08-28/29, on a fresh install of the same
image family. Separate board and separate symptom from the Gábor UART capture
in this directory; do not conflate them.

## What was reported

```
[@o6 ~]$ glmark2
Segmentation fault         (core dumped) glmark2
[@o6 ~]$ glmark2-es2
Error: eglGetDisplay() failed with error: 0x3000
Error: main: Could not initialize canvas
```

Earlier the same board reported an error about DRI3 not being available.
The reporter then said: "I switched to panfrost+panthor and it does offer
acceleration. I didn't dig that deep but it looked like the libMali shared
object just wasn't present."

Also reported: the board needs a hard reset rather than a software reboot.

## Where libMali comes from on a working board

Measured on our O6N (192.168.207.3) the same day:

```
dpkg -S libmali
  cix-gpu-umd: /opt/cixgpu-pro/lib/aarch64-linux-gnu/libmali.so.0.53.0
/proc/cmdline: sky1.gpu=vendor
/etc/ld.so.conf.d/: 00-cixgpu-pro.conf, 01-cixgpu-compat.conf, ...
```

`cix-gpu-umd` is NOT in `manifests/desktop.pkgs`. It is a bundled .deb —
`sbom/expected-assets.txt` lists `assets/cix-debs/cix-gpu-umd_2.0.0_arm64.deb`
— installed by post-install hook `25-cix-proprietary.sh`. Hook
`26-gpu-default-open.sh` then deliberately DEMOTES the CIX ld.so paths,
because (quoting our own `post-install/run-all.sh`) libmali is built for the
`mali_kbase` KMD while the image runs in-tree panthor, so leaving the CIX
userland ahead of Mesa yields "No mali devices found" and a broken libgbm.

So the intended end state of a default install is: vendor userland present but
demoted, Mesa/Panfrost active.

## Hypothesis, NOT yet confirmed

The reported failure is consistent with the board being in vendor GPU mode
(`sky1.gpu=vendor`, which is what our O6N boots with) while the vendor
userland is absent or not on the loader path — either hook 25 did not run, its
bundled .deb was missing from that ISO, or hook 26 demoted paths that hook 25
never populated. EGL then has no usable driver, `eglGetDisplay()` returns no
display, and glmark2 crashes; switching to panthor works because Mesa comes
from the distribution and is unaffected.

What would confirm it, on that board:

    cat /proc/cmdline | tr ' ' '\n' | grep sky1.gpu
    dpkg -l cix-gpu-umd
    ls -la /opt/cixgpu-pro/lib/aarch64-linux-gnu/libmali.so*
    cat /etc/ld.so.conf.d/00-cixgpu-pro.conf /etc/ld.so.conf.d/*cixgpu*
    ncz-gpu-select --status   (or whatever the installed switcher reports)

If that is the cause, the defect is that the mismatch is SILENT: a system can
boot asking for the vendor GPU stack with no vendor stack installed and say
nothing about it. Hook 25 should fail loudly when its asset is missing, and
the switcher should refuse to select a mode whose userland is not present.

## Relationship to the other report in this directory

None established. Gábor's board fails to bring up the display at all because
the DPU cluster exceeds DRM's 32-plane limit (see
`2026-08-29-gabor-orion-o6-analysis.md`). This board reaches a desktop and
lacks GPU acceleration. Different layers, different boards; they should not be
merged into one investigation without evidence.


## Known-good baseline, measured on our O6N the same day

Captured with `tools/ncz-gpu-report.sh` (added alongside this report):

```
cmdline : module_blacklist=panthor,typec_rts5453,rts5453   sky1.gpu=vendor
KMD     : /sys/bus/platform/drivers/mali -> CIXH5000:00, mali_kbase loaded, /dev/mali0 present
DRM     : card0 -> linlondp, renderD128 -> linlondp
package : ii  cix-gpu-umd  2.0.0  arm64
libmali : /opt/cixgpu-pro/lib/aarch64-linux-gnu/libmali.so.0.53.0
resolves: libEGL.so.1    -> /opt/cixgpu-compat/lib/aarch64-linux-gnu/libEGL.so.1
          libGLESv2.so.2 -> /opt/cixgpu-compat/lib/aarch64-linux-gnu/libGLESv2.so.2
          libgbm.so.1    -> /opt/cixgpu-pro/lib/aarch64-linux-gnu/libgbm.so.1
```

So a working O6N runs the VENDOR stack with panthor blacklisted on the kernel
command line. That sharpens the hypothesis: if a board keeps
`module_blacklist=panthor` and `sky1.gpu=vendor` while `cix-gpu-umd` is absent,
there is no GL driver at all — panthor is blocked and libmali does not exist.
EGL then has nothing to open, which is precisely the reported
`eglGetDisplay() failed with error: 0x3000` and the glmark2 crash, and it
explains why manually switching to panfrost/panthor restored acceleration.

This remains a hypothesis until the report script is run on that board.

## Note on the diagnostic itself

The first version of `ncz-gpu-report.sh` called `ldconfig` bare. `ldconfig`
lives in `/usr/sbin`, which is not on a normal user's PATH, so the script
reported libEGL, libGLESv2 and libmali as "not found" on our own O6N where
they demonstrably work. That false negative would have sent someone hunting a
missing library that was present the whole time. Fixed to resolve the binary
explicitly. Worth remembering: a diagnostic that reports absence must prove it
actually looked.
