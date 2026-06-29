# ISO release rule + current ISO

**Rule.** There is exactly **one valid ISO at a time**. Every time the ISO is rebuilt:
1. Bump the `r<N>` version and bake `~/iso-releases/ncz-installer-cixmini-26.6-r<N>-combined.iso`.
2. Update **README.md** (and translated READMEs) so the **"Current ISO"** section reflects the new `r<N>` and exactly what is in it.
3. **Remove previous-release noise** — no accumulated per-release history in the README; delete superseded GitLab/GitHub release pages and superseded ISO artifacts.
4. Commit + push (argonas → gitlab → github); cut a single GitLab/GitHub release for `v26.6-r<N>`.

**Current ISO:** `r142`. See README → *Current ISO*. Kernels 6.18.26-cix-sky1-lts (default) + 7.0.12-cix-sky1-next (edge); APT updates via Buildkite (`ncz-os/ncz`, kernels) + Codeberg (`ncz-os`, CIX bits); kernel source/recipes on GitLab `ncz-os/meta-cix`.

Mint: `bash build/build-iso-di.sh --variant desktop --version r<N> --bookworm-iso downloads/debian-12.13.0-arm64-netinst.iso --root "$(pwd)" --output ~/iso-releases/ncz-installer-cixmini-26.6-r<N>-combined.iso --mode full`
