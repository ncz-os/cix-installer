# arm64 ISO offline-pool regression, 2026-09-19

Audited on ULTRA using both actual shipped files copied from
`jperlow@192.168.207.4:~/Downloads/ncz-iso/`. Evidence, complete unsquashfs
listings, extracted dpkg databases and sampled payloads are retained at
`/home/jasonperlow/Projects/iso-content-audit-20260919/`.

## Ground truth

| Content | Sep 18 pr251 | Sep 19 mkosi | Corrected repair1 |
|---|---:|---:|---:|
| ISO bytes | 5,666,844,672 | 4,266,995,712 | 5,685,719,040 |
| Distinct pool deb packages | 1,354 | 33 | 1,671 |
| base.squashfs bytes | 1,313,247,232 | 913,813,504 | 913,813,504 |
| desktop.squashfs bytes | 1,930,563,584 | 1,918,033,920 | 1,918,033,920 |
| desktop-hotfix.squashfs bytes | 11,714,560 | 11,759,616 | 11,759,616 |
| Installed packages in base status | 364 | 371 | 371 |
| Installed packages in desktop status | 1,694 | 1,699 | 1,699 |

`xorriso -osirrox on -extract` extracted each layer from each ISO;
`unsquashfs -lln` listed the actual files and privileged `unsquashfs` extracted
dpkg metadata and selected executables/backgrounds. Neither new installed
package inventory removes an old installed package. The desktop status is a
merged inventory, not a count of packages exclusive to the delta.

Actual desktop file listings confirm GIMP (`/usr/bin/gimp-3.2`), mpv,
WirePlumber, Xwayland, node, podman, `/usr/sbin/seatd`, fcitx5, Qt6 libraries,
GStreamer plugins, `/opt/chromium-ncz-sky1/chrome`, and
`/opt/google/chrome/chrome`. This independently substantiates the earlier
log-based presence claim; that claim alone was not sufficient evidence.
All four wallpaper packages have their actual images: NCZ 7, Singularity 3,
Brandon Perlow 7, Alex Jay Brady 8. No animated screensaver hacks, xscreensaver
package or swayidle package were added; the standing hook/manifest hold remains.

## Why the base shrank

Regular-file logical bytes fell by 441,173,254. The largest path-group reduction
is 436,787,658 bytes under `/usr/local/lib`, chiefly installer asset copies.
Examples absent from the new base include the 223,345,647-byte rescue tarball,
99,216,456-byte cix-ai-test deb, 25,889,528-byte cix-mesa deb and
18,056,044-byte cix-gpu-umd deb. These are already compressed assets, explaining
most of the roughly 400 MB compressed squashfs difference.

This was a fresh-host asset-staging difference, not a package pruning of the
base: `build_base()` conditionally copies available gitignored assets before
running its hooks. The real new ISO carries rescue, sinty-nm, firmware and
vendor deb assets separately under `/cixmini/assets`; the corrected ISO retains
those. There is also a real runtime difference: the new base lacks the old
`/usr/bin/sinty-nmd` (7,536,824 bytes) and has NetworkManager plus its dependencies.
`19-sinty-nm.sh` explicitly takes this fallback when its build blob is absent;
it is rerun as an install-time hook using staged assets. Firmware file changes
also contribute about 7.85 MB. Do not describe this as every runtime file being
identical, or as an intentional mkosi deduplication policy. No full install or
hardware-network test was performed in this repair task.

## Cause

The ISO-only prune in commit `9d3e88b8` (August 4) intentionally removed debs
whose names appeared in any shipped layer's dpkg status, subject to a small
keep list. Its assumption that already-installed packages could never be
fetched was invalid for `apt-get --reinstall` and offline repair.

It also had a privilege-dependent failure: the status extraction was guarded
by `if unsquashfs ... && [ -f ... ]`. Replaying that exact extraction against
both shipped desktop layers as the regular user returns exit 2 on
`trusted.overlay.origin` at `/var/lib/dpkg`; both base extractions return 0.
The desktop status file exists despite exit 2, but the script ignores it.
Privileged extraction succeeds and enables pruning the whole desktop inventory.
The older build log reports 320 packages pruned from 1,674, leaving 1,354;
that matches pruning only the base. The new privileged assembly sees the
full inventory and leaves just 33. This reproduced mechanism explains the
host-dependent output; it is not evidence that desktop installed files vanished.

Reviewed actual diffs of `cb80f88`, `57f087b`, `00bcf1c`, and `9b7379c`.
They repair Debian source selection, architecture selection and build-time
mirror/container access; they did not introduce this prune. The ISO consumes
`build/forky-mirror`, whose resolver combines base and desktop seeds with the
Debian, desktop and vendor sources. It does not simply copy desktop-mirror.

The current tree does **not** substantiate a persistent on-disk offline apt
repository: `preseed/late.sh` explicitly strips CD-ROM sources before reboot.
Restoring the pool provides repair from mounted ISO media; it does not add a
persistent disk copy or an always-enabled source pointing at absent media.
The complete resolved closure is the shipping contract now enforced. It contains
1,671 packages, rather than freezing the old 1,354-name snapshot. Old pool names
`feh` (explicitly purged by desktop policy) and `yudit-common` are outside the
current resolved closure; this is not a promise to carry every historical deb
or every version recorded in a reused layer.

## Fix and verification

Removed the ISO-only pruning entirely. Added `verify-iso-offline-pool.py` after
index regeneration: every source Package/Version/Architecture must survive;
every staged archive must match Size/SHA256 in its index and the source mirror.
Also run the existing manifest seed gate against final staging. The new gate
rejects the actual bad staging with 1,638 missing package identities. Regression
tests cover retained packages, missing packages and corrupt archives.

Rebuilt with `build/build-iso-di.sh`, full mode, arm64, version
`2026.09.19-mkosi-arm64-repair1`, reusing the independently audited layers.
The three layers extracted from the corrected ISO compare byte-for-byte equal
to the audited Sep 19 layers. Extracted the final ISO pool and indexes and
reran the integrity gate: 1,671 resolved packages and archive hashes PASS.
All 226 manifest seeds survive. An isolated apt root with the extracted desktop
status and **only** the extracted ISO as a source successfully simulates
`--reinstall` of GIMP, mpv, WirePlumber, Chromium, Chrome, Xwayland, Node, Podman,
fcitx5 and Qt6. This is resolver verification, not execution of their maintainer
scripts on an installed machine.

The KVM kernel gate passed natively on the source kernel. Its SHA256 equals the
kernel extracted from the corrected ISO. A repeat using the extracted kernel
initially failed before boot at `KVM_CREATE_VM` due to host memory fragmentation;
reclaiming caches and compacting memory allowed the final artifact gate to
PASS with `accel=kvm cpu=host`, reaching the expected root-mount panic without
an oops. No guest RAM or gate criteria were weakened.

Corrected artifact:
`nclawzero-installer-cixmini-2026.09.19-mkosi-arm64-repair1.iso`

SHA256:
`4bf14c9e1ba23ee32d62a83ef681310747a0e36e755ba28ef5dd0524561e4d3d`

Delivery: `jperlow@192.168.207.4:~/Downloads/ncz-iso/`, with a matching `.sha256`
sidecar. The two original ISOs remain available for comparison.
