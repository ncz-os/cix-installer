# trixie d-i graft feasibility

Remote evidence is blocked in this Codex sandbox.

Command run:
`ssh -o BatchMode=yes -o ConnectTimeout=10 jasonperlow@192.168.207.22 '...'`

Output observed:
`ssh: connect to host 192.168.207.22 port 22: Operation not permitted`

Verbose retry showed the failure at connect(2), before auth:
`debug1: connect to address 192.168.207.22 port 22: Operation not permitted`

Q1: not answered. I could not grep `/tmp/bw-init` for `debootstrap_program` or `cdebootstrap`. Verdict: blocked; do not assume the preseed key exists.

Q2: partially answered locally. Command:
`rg -n "Packages.gz|debian-installer|pool|apt-ftparchive" build/build-iso-di.sh`
Output includes current merge/copy logic at lines 301-315 and Release regeneration at 319-329, but no regeneration of `dists/questing/main/debian-installer/binary-arm64/Packages(.gz)` after a udeb swap. Verdict: `build-iso-di.sh` needs d-i Packages regeneration; use `pool/main/d/debootstrap/` for the trixie udeb. Architecture: all acceptance by anna is blocked pending ARGOS grep.

Q3: not answered. I could not run the requested `/tmp/bw-init/bin /usr/bin` listing. Verdict: blocked; tool availability must be verified before trusting debootstrap.

Q4: not answered. I could not run `objdump -p /tmp/bw-init/usr/bin/dpkg-deb`. Verdict: blocked; if `libzstd.so.1` is absent from NEEDED, swap trixie's `dpkg-deb` too.

Q5: not answered. I could not grep bookworm `base-installer.postinst`. Verdict: blocked; patching vs preseed override cannot be decided here.

Local preseed command:
`rg -n "debootstrap_program|debootstrap_script|cdebootstrap|base-installer" preseed/preseed-ubuntu.cfg`
Observed key line:
`157:d-i base-installer/debootstrap_script string gutsy`

Minimal delta snippets for `build-iso-di.sh` after bookworm udebs are merged:

```sh
TRIXIE_DEBOOTSTRAP_UDEB="${TRIXIE_DEBOOTSTRAP_UDEB:-$ROOT/vendor/debootstrap-udeb_1.0.141_all.udeb}"
[ -f "$TRIXIE_DEBOOTSTRAP_UDEB" ] || { echo "ERROR: missing $TRIXIE_DEBOOTSTRAP_UDEB"; exit 1; }
rm -f "$STAGING"/pool/main/c/cdebootstrap/cdebootstrap-static_*.udeb
mkdir -p "$STAGING/pool/main/d/debootstrap"
cp "$TRIXIE_DEBOOTSTRAP_UDEB" "$STAGING/pool/main/d/debootstrap/"
mkdir -p "$STAGING/dists/questing/main/debian-installer/binary-arm64"
( cd "$STAGING" && dpkg-scanpackages -m -t udeb pool /dev/null \
  > dists/questing/main/debian-installer/binary-arm64/Packages )
gzip -9cn "$STAGING/dists/questing/main/debian-installer/binary-arm64/Packages" \
  > "$STAGING/dists/questing/main/debian-installer/binary-arm64/Packages.gz"
```

```sh
TRIXIE_INIT="${TRIXIE_INIT:-/tmp/tx-init}"
LIB_WORK="$STAGING/.trixie-lib-overlay"
rm -rf "$LIB_WORK"; mkdir -p "$LIB_WORK"
( cd "$TRIXIE_INIT" && find . \( -name 'libzstd.so.1*' -o -name 'liblzma.so.5*' \) -print | cpio -pdm "$LIB_WORK" )
( cd "$LIB_WORK" && find . -mindepth 1 -print | cpio -o -H newc --quiet | gzip -9 -n ) >> "$STAGING/install.a64/initrd.gz"
rm -rf "$LIB_WORK"
```

```sh
printf '\nd-i base-installer/debootstrap_program string debootstrap\n' >> "$EXTRA/preseed.cfg"
# If ARGOS shows base-installer hardcodes cdebootstrap, append a cpio overlay
# replacing var/lib/dpkg/info/base-installer.postinst with cdebootstrap -> debootstrap patched.
```
