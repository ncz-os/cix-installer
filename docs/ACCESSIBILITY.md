# Accessibility

## Braille displays (BRLTTY)

The NCZ-OS installer and the installed image do **not** include braille
support. BRLTTY is not in the installer and is not installed or preconfigured
on the installed system.

To use a refreshable braille display, install BRLTTY after the installation:

```sh
sudo apt install brltty
```

BRLTTY comes from the Debian archive (package `brltty`, section `admin`). It
starts automatically for a supported USB braille display once installed; see
`/usr/share/doc/brltty/` and `man brltty` for drivers, tables and
configuration (`/etc/brltty.conf`).

### Why the installer has no braille support

The Debian Installer normally carries BRLTTY (`brltty-udeb`) so that a blind
user can install with a braille display. In that installer BRLTTY starts on its
own whenever:

- the kernel command line contains the text `brltty` anywhere, or
- a USB device matches one of its device ids. That list includes the common
  USB-to-serial chips (FTDI, Silicon Labs CP210x, QinHeng CH341) used by
  serial debug cables and many other devices.

Once it runs, it narrows the installer console to 80 columns, turns the
graphical frontend off and can ask whether a USB serial device is a braille
display. On ordinary hardware without any braille display this made the
installer screen narrow and hard to use, so NCZ-OS removes BRLTTY from the
installer at build time and the build checks that it stays removed.

The trade-off: a blind user cannot use a braille display during the NCZ-OS
installation itself. The installed system supports braille as soon as
`brltty` is installed from the Debian archive.

### Build checks

- `build/iso/patch-initrd-t2-kernel.py` drops every `brltty-udeb` file and its
  package record from the installer initrd and fails the build if any remains.
- `build/iso/write-usb-image.py` keeps braille packages out of the medium's
  package pool and fails if one is present.
- `build/check-layers.sh` fails a layer that contains BRLTTY files or
  packages (`no-braille`).
- `build/iso/build-refind-esp.py` refuses an installer boot entry whose
  options contain `brltty`.
- `build/kvm-install-gate-gpt.sh` boots the installer with an emulated USB
  braille display, a USB serial adapter, a USB keyboard and a USB mouse
  attached and requires: no BRLTTY process and the installer console at full
  width (`build/kvm-installer-probe.sh`).
