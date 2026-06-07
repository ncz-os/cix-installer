# Installer rescue requirement

Operator rule, effective 2026-06-07:

Every new CIX/cixmini installer image must be rescue-equivalent.

Minimum requirements:

- The installer must remain bootable as normal install media.
- The same media must expose a rescue path with:
  - easy LAN shell access: telnet preferred; `nc` shell acceptable only when telnetd is unavailable in the initrd
  - file transfer: HTTP browser/upload/download and/or scp/sftp/rsync
  - read-only local filesystem mounts by default
  - explicit helper to remount a chosen target rw
  - helper to repair usrmerge `/lib -> usr/lib`
  - helper to force a known-good boot entry/default
  - enough disk/network tools to inspect and recover a broken install
- Output must be suitable for Balena Etcher:
  - partitioned raw USB `.img`, or
  - verified hybrid ISO with MBR/GPT partition visibility
  - no bare ISO9660-only artifacts that trigger a no-partition-table warning as the primary rescue deliverable
- Commit and push after every milestone.

Rationale: cixmini is unstable during kernel bring-up; prior sessions lost live state and broke rescue assumptions.
