# ISO release rule + current ISO

**Rule.** There is exactly **one valid ISO at a time**. Every time the ISO is rebuilt:
1. Rebuild the squashfs layers that changed (`bash build/build-squashfs-layers.sh {base|desktop|server|all}` — `base` only if the shared debootstrap/kernel/firmware/Mesa layer itself changed; `desktop`/`server` if their respective post-install hooks or package manifests changed), then bake the ISO (`make iso`, which wraps `build/build-iso-di.sh`). Bump the `r<N>` version.
2. Update **README.md** (and translated READMEs) so the **"Current ISO"** section reflects the new `r<N>` and exactly what is in it.
3. **Remove previous-release noise** — no accumulated per-release history in the README changelog beyond the last 4-5 entries; delete the superseded GitLab release page and superseded ISO package-registry artifacts (`glab api -X DELETE projects/ncz-os%2Fcix-installer/packages/<id>`).
4. Commit + push (argonas → gitlab). GitHub (`github.com/ncz-os/cix-installer`) is a **frozen, docs-only, archived mirror** — it never gets a release, never gets ISO binaries, never gets source pushes. Only rebuild its docs-only orphan commit if the docs themselves changed; do not create GitHub releases or tags (any that exist there are leftover from before this repo became a mirror and should be deleted, not added to).

**Current ISO:** `r195`. See README → *Current ISO*. Kernels 7.0.12-cix-sky1-next (default/stable) + 7.2.0-rc1-ncz (edge), built under Yocto 6.0 Wrynose; 6.18 LTS retired. Kernel + CIX-userspace updates via the public Cloudflare R2 apt repository (r195 kernel debs pending publication at time of writing); kernel source/recipes on GitLab `ncz-os/meta-cix` (patches tracked as files, kernel itself from public kernel.org). Both **Reinhardt** (desktop) and **Magnetar** (server) variants ship on the same ISO (layered squashfs — `base.squashfs` + `desktop.squashfs`/`server.squashfs`, rEFInd picks at boot). A dedicated NCZRESCUE recovery partition (full toolset + self-configuring network, verified as a release gate, see README → *Rescue partition*) ships on every install regardless of variant.

Mint:
```bash
bash build/build-squashfs-layers.sh all   # rebuild base+desktop+server squashfs layers
make iso                                   # wraps build/build-iso-di.sh, produces build/nclawzero-installer-cixmini-<date>.iso
```
