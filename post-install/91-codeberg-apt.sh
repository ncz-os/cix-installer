#!/bin/bash
# 91-codeberg-apt.sh — wire the NCZ apt repository to the Codeberg ncz-os Debian
# registry (kernel + CIX binary bits). Replaces the retired GHCR squashfs OTA
# (old 90-ota-channel.sh.disabled). The file:///cdrom source is already removed
# post-install by preseed/late.sh strip_cdrom_sources(); this hook installs the
# persistent online source so apt works after install. Decision 2026-06-28.
set -euo pipefail
echo "[91] wiring Codeberg ncz-os apt repository"

KEYRING=/usr/share/keyrings/ncz-codeberg-archive-keyring.gpg
SRC=/etc/apt/sources.list.d/ncz-codeberg.list
CB_URL="https://codeberg.org/api/packages/ncz-os/debian"

install -d /usr/share/keyrings /etc/apt/sources.list.d

# Embedded Codeberg ncz-os Debian registry signing key (armored -> dearmored).
cat > /tmp/ncz-codeberg.key.asc <<KEYBLOCK
-----BEGIN PGP PUBLIC KEY BLOCK-----

xsBNBGpAM1sBCAC9aERfG7VXZTpJU8aKuzsNdef5lGrZRihkVT05CoeElv6+nKOB
cFgeiallIdoRyFh4WwxPOOrt5Fv5BcCOyPh/keZ/fP+xZB/sYsjb6LqgLz8aDfzv
4UhPdP+DQFKAmsfbRtfUvY1J4MV0LOfQZgRDNrswlCV08zrfTkk05bV56LckZgfS
qdqXXumigElNQQeLiiliPzFMqMZbuHw2gGmH+vPvxPw9usC8Pct1LRFBsHOftbXE
rdqDjM+m/zszbGKG1L/24iiIVQXPRWD3VsdArapQb8XWICOu2szQb5vQzNgOQSuQ
6uk3NMtaxa5vFdn2A9iHRqpVH6cybSBfkJRxABEBAAHNEShEZWJpYW4gUmVnaXN0
cnkpwsC7BBMBCABvBYJqQDNbAgsHCRBXtoQDz4kyIDUUAAAAAAAcABBzYWx0QG5v
dGF0aW9ucy5vcGVucGdwanMub3Jn+WcSkP+L9eHY7H6Dwo+CGgIVCAIWAAIZAQKb
AwIeARYhBHGYshJ8avTYLXuJ41e2hAPPiTIgAADxAAf/ZmI/L8Gd/VCfCfcdLqmJ
ZojAw5KO+np5A4A4T3FKuUbJ3bopLb3CXDAyPs8e7ejC8qujHdpfIlBlo15IOQ6K
uXzMg3O99KCS8SsVD9w9vIDLr4pTgE+xPNIkt+6qiCcmkgt99gBepLIITfMvrkI+
/7iGwCMKRhigNqRai4igOtJ3kPg1aEpOlkZa/3z2CrTJokA5dCF5RJbm0GcQReVP
XIbFmEMY0026RPcU2GUJMgdYxGjj/8T66Nvg0WxA5HSf5ykDy9Y0JRe43NqFgT0n
tUAsWZUyTh3jhXQ7OiOAPrwFxZ0FLl2jySPsxrWKQquz1bjRot6ogQ0DNNISr/Gu
5M7ATQRqQDNbAQgA9PtEerd+1eCHJQvhmw1QJW73fUzabqUt2zcALirn0kjsX3fg
1Xd5i3mfnx7s1sISYGqKm0xsQHy1npQGjAi+vDIrbss4agt5+XzCOjQ086FKgTPf
fDcc9DOqxrbeVvhebywJWlK85E91bjbrz9iu0WUk/Cr38cJfQdjppvN/7sbawfXA
IUTvq1syisR6FzhI862rHwGEYJHT56aJMsidjQRjaA2WG6NNjItjLEbCUadgqPS7
aESmgyFFo0MVvJYMg8KssMPLELx5rteOxpL/M4m3ZgmHc9jauRWrFQ5ntuBryIhH
XH7XXQUQCXhz+0rgwfWX1/KoZEHWEveqQEJV9QARAQABwsCsBBgBCABgBYJqQDNb
CRBXtoQDz4kyIDUUAAAAAAAcABBzYWx0QG5vdGF0aW9ucy5vcGVucGdwanMub3Jn
yS93QbSmY2nz1LivTL4dLAKbDBYhBHGYshJ8avTYLXuJ41e2hAPPiTIgAABm5AgA
iKfChZWBvlvz8r29NeLtrutQdu5MqrVIPsgUYNd7nkc3AUJ29rNEydF1+tEWjUgi
ns4rBO8iCOGuK2Ffa8sAgVmBKGtV87xy+bif4qhVqW3MtPwX6eKiorzJ2+WACS01
Z7FrkiKwy743VckUekrdWnO/9I2RHTsdxg7BkDDrPF6xzQbvMPATp6GZp4HmUo+z
q49XLYS5ZI6qNIgr1Bap9GFo0t2Ou6nhKluD62PVgAvS1ZC/2aUN5ElV81Gdc//i
iEIAGUoNnO7j0Q5qHcxfT+1avib7g5wVogZceBj4Ox0aFyPaep4MzGt9yjxQS6Gj
gEbC/zDklcN28cQfh6WBFg==
=BYM6
-----END PGP PUBLIC KEY BLOCK-----
KEYBLOCK
gpg --dearmor < /tmp/ncz-codeberg.key.asc > "$KEYRING"
rm -f /tmp/ncz-codeberg.key.asc
chmod 0644 "$KEYRING"

cat > "$SRC" <<SRCEOF
# NCZ-OS apt repository — Codeberg ncz-os Debian registry (kernel + CIX bits)
deb [signed-by=$KEYRING] $CB_URL ncz main
SRCEOF

# Defensive: ensure the install-media cdrom source is gone (late.sh also strips it).
rm -f /etc/apt/sources.list.d/cixmini-cdrom.list /etc/apt/preferences.d/00cixmini-bootstrap-pool.pref 2>/dev/null || true

# ncz-update — apt against the Codeberg repo (replaces the squashfs OTA client).
install -d /usr/local/sbin
cat > /usr/local/sbin/ncz-update <<NCZUPDATE
#!/bin/bash
# ncz-update — update CIX/kernel packages from the Codeberg ncz-os apt repo.
#   ncz-update            list available cix/kernel upgrades
#   ncz-update --apply    apt update + upgrade the cix/kernel packages
#   ncz-update --status   show installed cix/kernel package versions
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "ncz-update: must run as root" >&2; exit 1; }
case "${1:-}" in
  --status) dpkg-query -W -f='  ${Package} ${Version}\n' 'linux-image-cixmini-*' 'cix-*' 'cixmini-*' 2>/dev/null || true; exit 0 ;;
esac
apt-get update -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/ncz-codeberg.list -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0
PKGS=$(apt-get -s upgrade 2>/dev/null | awk '/^Inst (cix-|cixmini-|linux-image-cixmini)/{print $2}')
echo "ncz-update: available cix/kernel upgrades:"; echo "${PKGS:-  (none)}" | sed 's/^/  /'
if [ "${1:-}" = "--apply" ]; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade $PKGS || true
fi
NCZUPDATE
chmod 0755 /usr/local/sbin/ncz-update
echo "[91] Codeberg apt source installed: $SRC (signed-by $KEYRING)"
