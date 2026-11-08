# Server console burn-in protection (blank, not animate)

Operator decision 2026-11-08. A headless server left on a console burns the
panel in; the server variant therefore blanks and powers the panel down when
idle. Nothing is animated beyond a dimmed status banner / optional wordmark.

## Policy

`/etc/ncz/console.conf` (installed by `post-install/48-server-variant.sh`):

| key | default | meaning |
|---|---|---|
| `NCZ_CONSOLE_BLANK` | `yes` | master switch |
| `NCZ_CONSOLE_IDLE_MIN` | `5` | minutes of console silence before the kernel blank |
| `NCZ_CONSOLE_POWERDOWN_MIN` | `1` | minutes after the blank before the panel powers down |
| `NCZ_CONSOLE_SAVER` | `none` | `wordmark` = drift the brand wordmark after 2 idle minutes |
| `NCZ_CONSOLE_BANNER` | `yes` | status banner: redraw the host/IP block once a minute after 1 idle minute, moving a few cells each time |

Mechanisms:
- server rEFInd/GRUB entries carry `consoleblank=300` (kernel blank);
- `ncz-console-blank.service` applies `setterm --blank <idle> --powerdown <powerdown>` to every VT and re-runs when a
  new VT appears (udev);
- `ncz-console-saver.service` owns the idle judgement (it reads the console, so any key stops the tier and resets the
  clock) and never writes after `NCZ_CONSOLE_IDLE_MIN`, so it cannot wake a blanked panel.

## Pool / test hosts

`fleet-ops` `temp-pool/provision/host/awake-enforcer.sh` follows the test lease: while a lease is held blanking is forced
off on every VT; with no lease the image policy above runs.

## Manual check (real panels)

On MEDUSA (or any server with a panel), after installing a current server image:

1. log in on the physical console (Alt+F2), note the time, leave the keyboard alone;
2. at ~5 minutes the screen blanks; at ~6 minutes the **panel should power down** (backlight off, no glow);
3. press a key: the panel wakes immediately and the login prompt returns;
4. optionally set `NCZ_CONSOLE_SAVER=wordmark` in `/etc/ncz/console.conf` and `systemctl restart ncz-console-saver`, then
   verify the dimmed wordmark drifts at ~2 minutes and stops on a key;
5. record the result (PASS + time) for the release notes; a panel that does not power down is a failure of
   `NCZ_CONSOLE_POWERDOWN_MIN`/DPMS support on that GPU.
