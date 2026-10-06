#!/bin/bash
# fixture hook: base seeds + staged pool deb + dkms
set -euo pipefail
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    gimp \
    htop 2>&1 | tail -3
dpkg -i pool/ncz-core_1.0_all.deb
dkms build
