#!/bin/bash
# 37-failsafe-access.sh — an UNWEDGEABLE break-glass recovery console that
# survives total /usr/lib destruction.
#
# WHY THIS EXISTS (burned the .66 main rootfs 2026-06-25):
#   A `tar -C /` of a Yocto modules tarball clobbered the usrmerge
#   /lib -> usr/lib symlink and orphaned ld-linux. Every DYNAMIC binary
#   then failed for ALL users incl. root — sshd (:22) and inetutils/busybox
#   telnetd (:23) accepted connections but could not exec a login shell, so
#   the box was fully locked out. The only recovery was the separate rescue
#   PARTITION. Operator directive: "all critical services in their own
#   library path — it cannot be wedged."
#
# THE FIX — its own library path == NO library path:
#   We stage a STATICALLY-linked busybox under /opt/ncz-failsafe (extracted
#   from the busybox-static .deb, NOT installed, so the dynamic system
#   busybox that initramfs-tools needs is left untouched). A static binary
#   has no PT_INTERP and zero /usr/lib dependency, and busybox reads
#   /etc/passwd + /etc/shadow directly (no NSS/PAM dlopen — which is why a
#   "private-libdir sshd" would NOT survive: glibc still dlopens libnss_*
#   from the broken /usr/lib). A systemd unit runs `busybox telnetd` on a
#   dedicated LAN port with a static, password-gated root shell as the login
#   program. Transport is telnet by design: LAN-only (192.168.207.0/24, no
#   public route) per fleet doctrine, where lockout recovery beats the
#   theoretical plaintext concern. Day-to-day encrypted access stays on
#   sshd:22 — this channel is break-glass ONLY.
#
# Phase 2 optional hook — must fail soft.
set +e

FS_ROOT=/opt/ncz-failsafe
FS_BIN="$FS_ROOT/bin"
FS_SBIN="$FS_ROOT/sbin"
FS_ETC="$FS_ROOT/etc"
FS_PORT=2323
# Default break-glass passphrase (operator-known fleet secret). Override at
# bake time by exporting NCZ_FAILSAFE_PASS before running the installer.
FS_PASS="${NCZ_FAILSAFE_PASS:-Gumbo@Kona1b}"

echo "[37] failsafe recovery console — static busybox on :$FS_PORT ($FS_ROOT)"
install -d -m 0755 "$FS_ROOT" "$FS_BIN" "$FS_SBIN"
install -d -m 0700 "$FS_ETC"

# ----------------------------------------------------------------------
# 1. Obtain a STATIC busybox without disturbing the system busybox.
# ----------------------------------------------------------------------
BB="$FS_BIN/busybox"
get_static_busybox() {
    local tmp deb d
    tmp=$(mktemp -d)
    # Pull from the (offline) pool; installer-base.pkgs lists busybox-static.
    if ( cd "$tmp" && apt-get download busybox-static 2>/dev/null ) && \
       deb=$(ls "$tmp"/busybox-static_*.deb 2>/dev/null | head -1) && [ -n "$deb" ]; then
        dpkg-deb -x "$deb" "$tmp/x" 2>/dev/null
        d=$(find "$tmp/x" -type f -path '*bin/busybox' 2>/dev/null | head -1)  # ELF binary, NOT the initramfs-tools conf file also named busybox
        if [ -n "$d" ]; then install -m 0755 "$d" "$BB"; rm -rf "$tmp"; return 0; fi
    fi
    rm -rf "$tmp"
    return 1
}

if get_static_busybox; then
    echo "[37] staged busybox-static -> $BB"
else
    # Last resort: copy the system busybox ONLY if it is itself static.
    SYS_BB=$(command -v busybox 2>/dev/null)
    if [ -n "$SYS_BB" ] && ! ldd "$SYS_BB" >/dev/null 2>&1; then
        install -m 0755 "$SYS_BB" "$BB"
        echo "[37] busybox-static unavailable; system busybox is static — copied $SYS_BB"
    else
        echo "[37] ERROR: no STATIC busybox available (busybox-static not in pool, system busybox is dynamic)."
        echo "[37]        Failsafe console would itself be wedged by /usr/lib damage — refusing to install a fake."
        echo "[37]        Add busybox-static to manifests/installer-base.pkgs and rebuild."
        exit 0
    fi
fi

# Hard verify the binary is genuinely static (no dynamic interpreter).
if ldd "$BB" >/dev/null 2>&1; then
    echo "[37] ERROR: $BB is dynamically linked — NOT unwedgeable. Aborting failsafe setup."
    rm -f "$BB"
    exit 0
fi
echo "[37] verified: $BB is statically linked ($(file -b "$BB" 2>/dev/null | cut -c1-40))"

# Convenience applet symlinks so a recovery operator has a normal toolset
# (all resolve to the single static binary).
for ap in sh ash ls cat cp mv rm mkdir chmod chown ln mount umount tar gzip \
          gunzip vi sed grep find df du ps kill ip ifconfig route ping cut awk \
          stat readlink dmesg sync reboot; do
    ln -sf busybox "$FS_BIN/$ap"
done

# ----------------------------------------------------------------------
# 2. Password gate. Prefer a sha512 hash verified by busybox cryptpw; fall
#    back to a 0600 plaintext secret only if this busybox lacks cryptpw.
# ----------------------------------------------------------------------
HASH=""
if HASH=$("$BB" cryptpw -m sha512 "$FS_PASS" 2>/dev/null) && [ -n "$HASH" ] && [ "${HASH#\$6\$}" != "$HASH" ]; then
    printf '%s\n' "$HASH" > "$FS_ETC/recovery.hash"
    chmod 0600 "$FS_ETC/recovery.hash"
    rm -f "$FS_ETC/recovery.secret"
    GATE=hash
    echo "[37] auth gate: sha512 hash (busybox cryptpw verified)"
else
    printf '%s' "$FS_PASS" > "$FS_ETC/recovery.secret"
    chmod 0600 "$FS_ETC/recovery.secret"
    rm -f "$FS_ETC/recovery.hash"
    GATE=plain
    echo "[37] auth gate: plaintext secret 0600 (busybox cryptpw unavailable in this build)"
fi

# ----------------------------------------------------------------------
# 3. Recovery login program — static shebang, password-gated root shell.
#    Interpreter is the static busybox, so this runs with /usr/lib gone.
# ----------------------------------------------------------------------
cat > "$FS_SBIN/recovery-shell" <<RECOVERY
#!$FS_BIN/busybox sh
# NCZ failsafe recovery shell — STATIC, independent of /usr/lib.
BB=$FS_BIN/busybox
export PATH=$FS_BIN HOME=/root TERM=\${TERM:-vt100}
\$BB stty sane 2>/dev/null
echo ""
echo "  ============================================================"
echo "   NCZ-OS FAILSAFE RECOVERY CONSOLE (static busybox)"
echo "   This shell survives /usr/lib damage. Use it to repair the"
echo "   main rootfs, then reboot. Common fix after a bad tar -C /:"
echo "     ls -ld /lib /usr/lib"
echo "     # if /lib is a real dir (should be a symlink): "
echo "     #   mv /lib /lib.broken && ln -s usr/lib /lib"
echo "     chown root:root /usr/lib && chmod 0755 /usr/lib"
echo "  ============================================================"
\$BB stty -echo 2>/dev/null
printf "  recovery passphrase: "
read PW
\$BB stty echo 2>/dev/null
printf "\n"
OK=1
if [ -f $FS_ETC/recovery.hash ]; then
    STORED=\$(\$BB cat $FS_ETC/recovery.hash)
    SALT=\$(printf '%s' "\$STORED" | \$BB cut -d'\$' -f1-3)
    CAND=\$(\$BB cryptpw -m sha512 "\$PW" "\$SALT" 2>/dev/null)
    [ -n "\$CAND" ] && [ "\$CAND" = "\$STORED" ] && OK=0
elif [ -f $FS_ETC/recovery.secret ]; then
    SECRET=\$(\$BB cat $FS_ETC/recovery.secret)
    [ "\$PW" = "\$SECRET" ] && OK=0
fi
if [ "\$OK" -ne 0 ]; then
    echo "  denied."
    exit 1
fi
echo "  access granted — root recovery shell (static). 'exit' to disconnect."
exec \$BB sh -l
RECOVERY
chmod 0755 "$FS_SBIN/recovery-shell"

# ----------------------------------------------------------------------
# 4. systemd unit — static telnetd on the dedicated failsafe port. Brought
#    up in normal, rescue AND emergency targets so it is reachable in every
#    boot state. ExecStart uses the static busybox directly (no shell, no
#    /usr/lib).
# ----------------------------------------------------------------------
cat > /etc/systemd/system/ncz-failsafe.service <<UNIT
[Unit]
Description=NCZ failsafe recovery console (static busybox telnetd :$FS_PORT) — survives /usr/lib damage
Documentation=file:$FS_ROOT/README
After=network.target
DefaultDependencies=no
Conflicts=shutdown.target

[Service]
Type=simple
# Static binary: no dynamic loader, no /usr/lib. -F=foreground (systemd
# supervises), -p=port, -l=login program (our static password gate).
ExecStart=$FS_BIN/busybox telnetd -F -p $FS_PORT -l $FS_SBIN/recovery-shell
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target rescue.target emergency.target
UNIT

systemctl enable ncz-failsafe.service 2>&1 | tail -1 || true

# ----------------------------------------------------------------------
# 5. Docs + operator-visible note.
# ----------------------------------------------------------------------
cat > "$FS_ROOT/README" <<DOC
NCZ-OS FAILSAFE RECOVERY CONSOLE
================================
Purpose : break-glass root shell that survives total /usr/lib damage
          (e.g. a bad 'tar -C /' that orphans ld-linux). Independent of
          the main rootfs libraries: a single STATIC busybox + a
          password-gated static login shell.
Reach   : telnet <box-ip> $FS_PORT   (LAN-only; fleet doctrine)
Auth    : recovery passphrase ($GATE gate). Default is the fleet secret;
          override at bake time via NCZ_FAILSAFE_PASS.
Layout  : $FS_BIN/busybox   (static, no libs)
          $FS_SBIN/recovery-shell  (login program)
          $FS_ETC/recovery.{hash,secret}  (0600)
          /etc/systemd/system/ncz-failsafe.service
Note    : day-to-day encrypted access stays on sshd:22; telnetd:23 is the
          dynamic backup; THIS ($FS_PORT) is the unwedgeable last resort.
DOC
chmod 0644 "$FS_ROOT/README"

if [ -d /etc/update-motd.d ]; then
    cat > /etc/update-motd.d/45-ncz-failsafe <<'MOTD'
#!/bin/sh
echo "Failsafe recovery console (survives /usr/lib damage): telnet <ip> 2323  — see /opt/ncz-failsafe/README"
MOTD
    chmod 0755 /etc/update-motd.d/45-ncz-failsafe
fi

echo "[37] DONE — failsafe console enabled on :$FS_PORT (static, gate=$GATE). Recovery is independent of /usr/lib."
