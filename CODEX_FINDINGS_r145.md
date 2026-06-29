build/build-iso-di.sh:1512 — MED — cp "$ROOT/build/apt-repo/"* fails if repo dir is empty — guard with a non-empty glob/find check.
build/build-iso-di.sh:1515 — MED — full mode copies active preseed unmodified, leaving stale partman/late_command — strip or fix it consistently in all modes.
build/build-iso-di.sh:1557 — HIGH — DIAG_ENABLE=1 assumes assets/diag/busybox-arm64 exists; missing file aborts build late — validate early or auto-disable diagnostics.
build/build-iso-di.sh:1570 — LOW — assets loop iterates literal glob if assets is empty — enable nullglob or guard with find.
build/build-iso-di.sh:1755 — HIGH — missing rEFInd only warns even though 70-bootloader will fail install — make it a build-time error.
build/build-iso-di.sh:2 — LOW — header describes obsolete Debian-to-Ubuntu late_command flow — update comments to current rootfs/debootstrap-stub flow.
build/build-iso-di.sh:761 — MED — debootstrap stub searches fixed media paths only — scan mounted filesystems for /cixmini/rootfs.tar.zst.
build/build-iso-di.sh:789 — MED — zstd|tar in stub has no pipefail — explicitly capture zstd and tar statuses.
post-install/09-diag-account.sh:30 — HIGH — creates magnetar:diags with passwordless sudo — gate to diagnostic builds and remove from production.
post-install/10-our-kernel.sh:50 — MED — required apt install depends on late.sh offline apt wiring; /cdrom bug can fail kernel install — fix media mount/source setup first.
post-install/12-sky1-firmware.sh:62 — LOW — cp "$SRC"/* fails if only dotfiles exist — use find or nullglob.
post-install/16-mesa-gpu-2613.sh:17 — MED — no set -e, so extraction/install failures can exit 0 — use set -euo pipefail or explicit rc checks.
post-install/20-desktop.sh:263 — MED — systemctl set-default/enable can abort optional desktop hook in chroot — guard or defer where appropriate.
post-install/20-desktop.sh:342 — MED — missing ncx-upstream-watch asset aborts the rest of desktop setup — guard install or make asset required at build time.
post-install/20-desktop.sh:414 — HIGH — VIVALDI_URL command substitution under pipefail aborts on network/page failure — append || true and handle empty.
post-install/20-desktop.sh:47 — MED — recreates file:///cdrom source without verifying /cdrom is mounted — check mountpoint/index first.
post-install/20-desktop.sh:490 — LOW — MIME default falls back to vivaldi-stable.desktop even if Vivaldi absent — choose an installed browser desktop file.
post-install/20-desktop.sh:8 — MED — mutates desktop skel before variant check; server builds can get desktop artifact — move variant check before desktop changes.
post-install/25-cix-ppa.sh:189 — MED — dpkg -l check can treat residual package state as installed — require status ii.
post-install/25-cix-ppa.sh:235 — MED — comment says hard-fail DKMS, code purges/continues in some paths — align behavior with requirement.
post-install/25-cix-ppa.sh:84 — MED — adds Debian trixie CIX repo to Ubuntu resolute — pin narrowly or use a matching suite.
post-install/25-cix-proprietary.sh:249 — BLOCKER — detects remaining btrfs blacklist but does not exit; btrfs root may be unbootable — exit 1 or make hook required-fatal.
post-install/25-cix-proprietary.sh:25 — MED — no set -e and final exit 0 hide critical package failures — make boot-critical checks hard-fail.
post-install/25-cix-proprietary.sh:254 — HIGH — apt-get install -fy may remove packages to resolve forced deps and result is ignored — inspect/simulate plan and fail on dangerous removals.
post-install/25-cix-proprietary.sh:276 — BLOCKER — purges every iU/iF package with --force-remove-essential, not just CIX packages — scope to known CIX debs and never force-remove-essential globally.
post-install/25-cix-proprietary.sh:291 — MED — dpkg-deb -x libnoe payload failures ignored — verify expected files or fail NPU userspace setup.
post-install/26-gpu-default-open.sh:37 — LOW — mv failure still prints success because set -e is off — check mv before logging.
post-install/30-agents.sh:1030 — MED — masks dkms.service globally, conflicting with future DKMS/VPU repairs — scope masking to known broken modules or remove.
post-install/30-agents.sh:27 — MED — podman install failure ignored but CLI/units still installed — verify podman or mark agent stack unavailable.
post-install/30-agents.sh:342 — MED — launchers hard-code /usr/bin/vivaldi-stable though browser is optional — use xdg-open or detected browser.
post-install/30-agents.sh:490 — LOW — .agents-installed is touched even if selected agents failed — write marker only after successful installs.
post-install/30-agents.sh:627 — LOW — desktop Exec quoting is fragile — call a wrapper script.
post-install/31-remote-access.sh:27 — MED — NoMachine install failure aborts before xrdp repair — make NoMachine best-effort.
post-install/31-remote-access.sh:35 — LOW — writes /etc/xrdp/startwm.sh even if xrdp dir absent — guard/create dir.
post-install/33-network.sh:116 — LOW — generated ifupdown source glob may fail if directory absent — create dir or use source-directory.
post-install/33-network.sh:125 — LOW — uses disable --now in chroot — avoid --now.
post-install/34-fstab.sh:125 — LOW — ESP vfat passno is 2 — use 0 for ESP unless fsck policy is intentional.
post-install/34-fstab.sh:54 — MED — derives mounts from chroot findmnt; if namespace differs, fstab can be wrong — log/derive from d-i target mountinfo robustly.
post-install/35-ssh.sh:137 — HIGH — config enables root SSH and password auth despite comments saying key-only — use PermitRootLogin prohibit-password and PasswordAuthentication no unless diagnostics.
post-install/35-ssh.sh:42 — MED — [Install] in drop-ins may not create rescue wants reliably — use systemctl add-wants or symlinks.
post-install/36-telemetry.sh:40 — LOW — assumes timeout exists — check command or run apt directly.
post-install/36-telemetry.sh:57 — MED — telnet unit can point to nonexistent busybox — verify executable before enabling.
post-install/36-telemetry.sh:71 — HIGH — telnet login is enabled — gate to diagnostics or disable in production.
post-install/37-failsafe-access.sh:167 — MED — service orders After=network.target but does not pull networking in rescue/emergency — add Wants/Requires for network service.
post-install/37-failsafe-access.sh:38 — HIGH — hard-coded recovery passphrase — require build-time secret or disable by default.
post-install/37-failsafe-access.sh:71 — MED — no static busybox exits 0, reporting success without failsafe — exit nonzero if feature is required.
post-install/37-ntp-hostname.sh:45 — LOW — depends on /sys in chroot for MAC hostname — verify bind mount or pass hardware info from installer.
post-install/38-recovery-container.sh:138 — MED — unguarded systemctl enable can abort after rootfs extraction — guard or fail earlier.
post-install/38-recovery-container.sh:56 — HIGH — nspawn recovery binds host root writable — restrict or require explicit recovery mode.
post-install/40-claude-code.sh:21 — MED — npm install has no timeout and can hang installer — use timeout or defer to first boot.
post-install/45-wallpaper-rotator.sh:23 — LOW — default.jpg can point to nonexistent wallpaper — require at least one asset before linking.
post-install/46-ncz-cli.sh:288 — LOW — sed replacement can break on image values containing & or delimiter — escape replacement or use env file templating.
post-install/46-ncz-cli.sh:30 — MED — CLI hard-codes /cdrom asset path — prefer staged /usr/local/lib/cix-installer asset.
post-install/47-embedkit.sh:162 — HIGH — ls in command substitution under set -e aborts before warning when wheels are missing — add || true.
post-install/47-embedkit.sh:185 — MED — network pip install is hard-fatal/offline-hostile — bundle wheel or make fallback explicit.
post-install/48-magnetar-variant.sh:49 — MED — systemctl set-default unguarded in optional hook — guard or make hook required.
post-install/48-magnetar-variant.sh:61 — LOW — NoMachine path hard-codes /cdrom — use staged assets.
post-install/48-magnetar-variant.sh:82 — HIGH — SSH enable failure is logged but install continues for headless SKU — fail Magnetar install if ssh cannot be enabled.
post-install/50-brand.sh:31 — LOW — changes ID to ncz, risking Ubuntu tooling compatibility — keep ID=ubuntu and brand via PRETTY_NAME or verify consumers.
post-install/56-icon-theme.sh:170 — LOW — empty MATE heredoc despite comment — remove or add intended settings.
post-install/56-icon-theme.sh:34 — LOW — rm -rf old theme before copy can leave no theme if copy fails — copy to temp then rename.
post-install/70-bootloader.sh:274 — HIGH — ESP is wiped before all new files are successfully written — stage to temp, verify/fsync, then replace.
post-install/70-bootloader.sh:277 — MED — rm -rf /boot/efi/[0-9a-f]* matches any hex-prefixed path, not only machine-id dirs — restrict with exact 32-hex match.
post-install/72-rescue-partition.sh:118 — MED — module extraction failure can still write readiness marker — verify modules/depmod before marker.
post-install/72-rescue-partition.sh:150 — MED — marker can be written with empty PARTUUID — require nonempty PARTUUID.
post-install/72-rescue-partition.sh:58 — HIGH — fallback-by-elimination can format an arbitrary spare partition — require NCZRESCUE label/PARTLABEL/expected partition number and size.
post-install/72-rescue-partition.sh:65 — MED — lsblk PKNAME on btrfs source with subvol suffix can fail — strip [subvol] before lsblk.
post-install/80-npu.sh:222 — MED — idempotence checks only first CPIO magic, so unrelated early CPIO suppresses SSDT prepend — check for a marker file/content.
post-install/80-npu.sh:227 — MED — failed cat/mv of initrd produces no warning under set +e — add else/error logging.
post-install/80-npu.sh:243 — LOW — modules-load always requests armchina_npu even if no module installed — write only when module exists.
post-install/80-npu.sh:28 — MED — set +e hides initrd/module mutation failures — explicitly fail or warn on each critical operation.
post-install/90-ota-channel.sh.disabled:188 — MED — skopeo path picks largest dir member as layer — parse manifest.json for real layer order.
post-install/90-ota-channel.sh.disabled:244 — LOW — unquoted/empty PKGS can run apt-get with no package list — guard [ -n "$PKGS" ].
post-install/90-ota-channel.sh.disabled:76 — MED — --image does not validate a following argument — check $# before shift 2.
post-install/91-codeberg-apt.sh:51 — MED — no fingerprint verification after dearmor — verify expected fingerprint before installing keyring.
post-install/91-codeberg-apt.sh:80 — MED — generated ncz-update ignores apt apply failures — return nonzero on failed upgrade.
post-install/92-buildkite-apt.sh:14 — MED — gpg missing aborts repo setup under set -e — include gnupg dependency or fail with clear required message.
post-install/92-buildkite-apt.sh:16 — MED — token read preserves whitespace/newlines into auth.conf — trim to one token line.
post-install/99-diagnostics.sh:186 — HIGH — rescue docs tell operators root is /dev/nvme0n1p2; active layout makes p2 rescue and p3 root — change docs to p3 or tell users to identify by blkid/lsblk.
post-install/99-diagnostics.sh:66 — LOW — unmatched loader-entry glob logs literal path noise — guard with [ -e "$f" ].
post-install/apt-progress-shim:10 — LOW — case " $* " loses argument boundaries — parse argv subcommand explicitly.
post-install/run-all.sh:183 — LOW — empty optional hook list counts as 1 — use grep -c .
post-install/run-all.sh:27 — HIGH — cd happens before set -e; failure runs from wrong directory — move set -euo pipefail before cd or use cd || exit 1.
preseed/diag-console.sh:84 — HIGH — predictable root password and HTTP serving / are enabled by diagnostics — gate behind ncz_diag=1 only and disable in ship builds.
preseed/diag-console.sh:94 — MED — pidfile captures a pipeline/background PID unreliably — run a supervised wrapper or use syslogd remote logging.
preseed/extract-rootfs.sh:30 — MED — rootfs source discovery misses arbitrary mounted media — scan /proc/mounts like early_command.
preseed/extract-rootfs.sh:98 — MED — zstd|tar runs under sh without pipefail, so decompressor failure can be masked — use explicit status handling or bash pipefail.
preseed/late.sh:188 — HIGH — offline apt detection hard-codes /cdrom even when SRC is elsewhere — derive cdrom root from SRC.
preseed/late.sh:195 — MED — bind mount never sets CDROM_BIND_MOUNTED=1, so cleanup at line 400 never unmounts — set the flag after a successful mount.
preseed/late.sh:199 — MED — writes cixmini-offline.list even if /cdrom/cixmini/apt-repo is absent — guard on repo directory/index.
preseed/late.sh:340 — LOW — hook counting word-splits HOOK_NAMES — use printf with quoted variable and grep -c .
preseed/late.sh:88 — MED — source discovery uses fixed paths only — reuse the early_command /proc/mounts NCZSRC scan.
preseed/preseed-ubuntu.cfg:125 — LOW — /proc/mounts scan reads only three fields and does not decode escaped mount paths — parse mountinfo or read all fields safely.
preseed/preseed-ubuntu.cfg:198 — MED — allow_unauthenticated=true trusts the embedded mirror globally — sign the embedded Release or scope trust to the local file source only.
preseed/preseed-ubuntu.cfg:254 — BLOCKER — GPT zap still hard-codes /dev/nvme0n1 before the operator-selected disk, contradicting the r130 safety model and missing other selected disks — move disk wiping to the actual selected disk or preseed one disk explicitly.
preseed/preseed-ubuntu.cfg:254 — HIGH — dd zap has no sync, blockdev --rereadpt/partprobe, or udev settle; partman can see stale partition state — add sync; blockdev --rereadpt "$D" || partprobe "$D"; udevadm settle.
preseed/preseed-ubuntu.cfg:255 — BLOCKER — mkfs wrapper misses likely invocation names/paths such as mkfs.vfat and PATH-resolved variants — wrap mkfs.fat, mkdosfs, mkfs.vfat in every /sbin,/usr/sbin,/bin,/usr/bin location or install a PATH shim used by partman.
preseed/preseed-ubuntu.cfg:255 — HIGH — root cause is missing codepage/gconv support; stderr-only filtering is fragile — ship the needed CP850/iconv gconv data in the d-i initrd or force a supported FAT codepage if dosfstools supports it.
preseed/preseed-ubuntu.cfg:255 — HIGH — wrapper only applies if mkfs exists when partman/early_command runs; dosfstools may be loaded later — force/load dosfstools-udeb before wrapping or hook after udeb load and log command -v results.
preseed/preseed-ubuntu.cfg:255 — MED — wrapper suppresses all mkfs stderr, hiding real FAT failures — filter only the known CP850 iconv warning, log other stderr, and preserve nonzero exits.
preseed/preseed-ubuntu.cfg:267 — MED — partman/late_command is documented in the file but build comments say it is not a real preseed hook; extract-rootfs.sh may never run — remove it or patch d-i explicitly; keep one real extraction path.
preseed/preseed-ubuntu.cfg:288 — HIGH — recipe says ESP is 2048 while comments say 4 GiB — change p1 size triplet to 4096 4096 4096 if 4 GiB is required.
preseed/preseed-ubuntu.cfg:290 — LOW — ESP stanza relies only on method{ efi } format{ } and lacks explicit use_filesystem/filesystem fat32 — add explicit FAT filesystem fields if accepted by this partman version.
preseed/preseed-ubuntu.cfg:493 — MED — late_command hard-codes /cdrom/cixmini/late.sh unlike the legacy fallback — use the /cdrom,/hd-media,/media,/proc/mounts discovery path.
preseed/preseed-ubuntu.cfg.pre-btrfs.20260622-022052:242 — HIGH — backup preseed still destructively hard-codes /dev/nvme0n1 — remove from deployable tree or mark non-build artifact.
preseed/preseed.cfg:1 — MED — legacy file claims canonical but does not match active btrfs/rescue layout — rename to legacy or sync with preseed-ubuntu.cfg.
preseed/preseed.cfg:159 — HIGH — legacy recipe creates only ESP plus ext4 root, no rescue/btrfs; accidental use installs the wrong layout — delete or clearly exclude from builds.
preseed/sshd-watcher.sh:121 — MED — generated pre-pkgsel hook hard-codes /cdrom for bootstrap pool — use discovered media root.
preseed/sshd-watcher.sh:205 — MED — overwrites udhcpc default.script wholesale — patch/extend existing script instead.
