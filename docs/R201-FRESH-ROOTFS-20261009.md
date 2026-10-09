# R201 direct fresh rootfs inputs, 2026-10-09

Both management and rescue rootfs inputs were rebuilt directly by the
orchestrator from clean, GitLab-pushed producer
`0d5c99113e9b54ce4e07ce869a016e02bd8a777f`.
AMD64 ran in the owned Debian Forky container on HYDRA .78; ARM64 ran in the
owned Debian Forky container on ULTRA .88 (not the Fedora host).
Build roots/TMPDIR were on each host's physical Projects filesystem, not tmpfs.

Builders authenticated the committed Debian snapshot `20261007T202437Z` and
simulated zero-removal transactions before each package installation/repair.
Rescue runtime, identity, inetd and same-kernel contract checks passed.
The strict provenance scanner checked all packages against 107354 authenticated
snapshot index entries; no unknown, old-snapshot or Ubuntu package was accepted:

| Rootfs | Packages checked | Failures |
| --- | ---: | ---: |
| AMD64 management | 149 | 0 |
| AMD64 rescue | 392 | 0 |
| ARM64 management | 149 | 0 |
| ARM64 rescue | 389 | 0 |

The initial scan rejected the correct snapshot source solely for its single
trailing slash. The source comparison now accepts that spelling of the exact
pinned snapshot path. Tests continue rejecting changed timestamps, child paths,
other suites, double slashes, traversal and query strings.

The exact four compressed archives were then independently extracted through
the verifier's safe tar extractor into new owned directories and rescanned.
Both native-container archive checks exited 0 with the same package counts and
zero failures (`amd64-archive-verification.log` and
`arm64-archive-verification.log`).

Publication used the canonical `build/stage-build-inputs.sh --publish` with
owned external staging trees/TSV copies so the producer checkouts remained clean.
The four rewritten pin rows in `manifests/build-inputs.tsv` are copied from
those actual generated TSVs, not manually calculated claims. Each uploaded
archive hash was independently verified by the publisher. Publication affected
only the non-live `ncz-os-assets/build-inputs/{amd64,arm64}/assets/{mgmt,rescue}`
inputs, not a live package repository or an image release.

Old store bytes matched the prior committed pins before replacement and were
preserved recoverably on each build host under
`/home/jasonperlow/Projects/ncz-r201-direct-build-20261009/prior-rootfs-<arch>/`.
Local publication receipts and AMD64/ARM64 strict scan logs are retained under
`/Users/jasonperlow/Projects/ncz-r201-direct-build-evidence-20261009/`.

This proves refreshed rootfs inputs, not finished image builds or fresh-install
acceptance. The combined source still needs remaining package/layer provenance,
full image composition and KVM/finished-image gates. The frozen image kernel and
separate warning-followup work are unchanged.
