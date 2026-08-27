#!/bin/bash
# build-dkms-debs.sh — package the accelerator DKMS sources as real .debs.
#
# WHY THIS EXISTS.
#
# All four accelerator modules are built and working on a shipped system, but
# only ONE of them is owned by dpkg. Measured on an O6N running the current
# image:
#
#   dkms status              dpkg -l
#   aipu/6.2.0        ok     cix-npu-driver-dkms  6.2.0-...   <- packaged
#   cix-gpu-kmd/1.0   ok     (absent)                          <- not packaged
#   panthor-cix/7.2.0 ok     (absent)                          <- not packaged
#   cix-vpu-driver/…  ok     (absent)                          <- not packaged
#
# The post-install hooks copy the sources into /usr/src and run `dkms add`
# directly, so dpkg never learns the files exist. The consequence is that three
# of the four drivers have NO UPDATE PATH: apt cannot upgrade a package it does
# not know about, and there is nothing to publish to the repo. 82-mali-gpu.sh
# says as much in its own comments -- it refers to a cix-gpu-dkms .deb and adds
# "Nothing in this repo ever built that deb".
#
# This builds them, using EXACTLY the staging rule each hook already uses, so a
# package contains what the hook would have copied and nothing else:
#
#   mali    src/ + dkms.conf
#   vpu     src/ + dkms.conf
#   npu     src/ + dkms.conf
#   panthor the whole asset dir minus build artifacts and the patches/ dir
#
# Usage: build/build-dkms-debs.sh [driver ...]     (default: all four)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/dkms-debs"
DRIVERS=("$@")
[ ${#DRIVERS[@]} -eq 0 ] && DRIVERS=(mali panthor vpu npu)

conf_get() {  # conf_get <file> <key>
    sed -n "s/^$2=\"\{0,1\}\([^\"]*\)\"\{0,1\}[[:space:]]*$/\1/p" "$1" | head -1
}

install -d "$OUT"
built=0

for drv in "${DRIVERS[@]}"; do
    ASSET="$ROOT/assets/kernel/$drv"
    CONF="$ASSET/dkms.conf"
    if [ ! -f "$CONF" ]; then
        echo "SKIP $drv: no dkms.conf at $CONF" >&2
        continue
    fi

    NAME="$(conf_get "$CONF" PACKAGE_NAME)"
    VER="$(conf_get "$CONF" PACKAGE_VERSION)"
    if [ -z "$NAME" ] || [ -z "$VER" ]; then
        echo "SKIP $drv: dkms.conf has no PACKAGE_NAME/PACKAGE_VERSION" >&2
        continue
    fi

    WORK="$(mktemp -d)"
    SRCDIR="$WORK/usr/src/${NAME}-${VER}"
    install -d "$WORK/DEBIAN" "$SRCDIR" "$WORK/usr/share/doc/${NAME}"

    # Mirror the hook's staging rule for this driver.
    case "$drv" in
        panthor)
            cp -a "$ASSET"/. "$SRCDIR"/
            rm -f  "$SRCDIR"/*.o "$SRCDIR"/*.ko "$SRCDIR"/*.mod* \
                   "$SRCDIR"/Module.symvers "$SRCDIR"/modules.order 2>/dev/null || true
            rm -rf "$SRCDIR"/patches 2>/dev/null || true
            ;;
        *)
            if [ -d "$ASSET/src" ] && [ -n "$(ls -A "$ASSET/src" 2>/dev/null)" ]; then
                cp -a "$ASSET/src"/. "$SRCDIR"/
            else
                echo "SKIP $drv: $ASSET/src is empty and no special rule applies" >&2
                rm -rf "$WORK"; continue
            fi
            cp -a "$CONF" "$SRCDIR/dkms.conf"
            ;;
    esac

    # A DKMS package with no buildable source is worse than no package: it
    # installs clean and then fails at module build time on the target.
    if [ -z "$(ls -A "$SRCDIR" 2>/dev/null)" ]; then
        echo "SKIP $drv: staged source tree is empty" >&2
        rm -rf "$WORK"; continue
    fi
    [ -f "$SRCDIR/dkms.conf" ] || { echo "SKIP $drv: no dkms.conf staged" >&2; rm -rf "$WORK"; continue; }

    SIZE_KB=$(du -sk "$WORK/usr" | cut -f1)
    DEB_VER="${VER}+ncz${NCZ_DKMS_DEB_REV:-1}"

    cat > "$WORK/DEBIAN/control" <<CONTROL
Package: ${NAME}-dkms
Version: ${DEB_VER}
Section: kernel
Priority: optional
Architecture: all
Maintainer: Jason Perlow <jperlow@gmail.com>
Installed-Size: ${SIZE_KB}
Depends: dkms (>= 2.1.0.0)
Provides: ${NAME}
Description: ${NAME} kernel module (DKMS source)
 DKMS source for the ${NAME} module used by NCZ-OS on CIX Sky1 hardware.
 .
 The module is rebuilt automatically against each installed kernel, so it
 survives kernel upgrades instead of being silently replaced by an in-tree
 copy of the same name.
CONTROL

    cat > "$WORK/DEBIAN/postinst" <<POSTINST
#!/bin/sh
set -e
NAME="${NAME}"
VER="${VER}"
case "\$1" in
  configure)
    # Register and build. Failure to BUILD is not made fatal: a target without
    # matching kernel headers should still end up with the source staged and
    # dkms aware of it, so a later 'dkms autoinstall' picks it up. Failure is
    # reported rather than hidden.
    if command -v dkms >/dev/null 2>&1; then
        dkms add -m "\$NAME" -v "\$VER" >/dev/null 2>&1 || true
        if ! dkms autoinstall -m "\$NAME" -v "\$VER" >/dev/null 2>&1; then
            echo "\$NAME: dkms build deferred (no matching kernel headers?)." >&2
            echo "  run: dkms autoinstall -m \$NAME -v \$VER" >&2
        fi
    else
        echo "\$NAME: dkms is not installed; source staged only." >&2
    fi
    ;;
esac
exit 0
POSTINST

    cat > "$WORK/DEBIAN/prerm" <<PRERM
#!/bin/sh
set -e
NAME="${NAME}"
VER="${VER}"
if command -v dkms >/dev/null 2>&1; then
    dkms remove -m "\$NAME" -v "\$VER" --all >/dev/null 2>&1 || true
fi
exit 0
PRERM

    chmod 0755 "$WORK/DEBIAN/postinst" "$WORK/DEBIAN/prerm"

    printf 'DKMS source for %s %s, packaged from assets/kernel/%s.\n' \
        "$NAME" "$VER" "$drv" > "$WORK/usr/share/doc/${NAME}/README.Debian"

    DEB="$OUT/${NAME}-dkms_${DEB_VER}_all.deb"
    dpkg-deb --build --root-owner-group "$WORK" "$DEB" >/dev/null
    rm -rf "$WORK"
    echo "built: $(basename "$DEB")  ($(du -h "$DEB" | cut -f1))"
    built=$((built + 1))
done

echo "---"
echo "$built package(s) in $OUT"
[ "$built" -gt 0 ] || { echo "nothing built" >&2; exit 1; }
