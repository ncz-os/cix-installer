#!/bin/bash
# refresh-vivaldi.sh -- move Vivaldi to the newest vivaldi-stable.
#
# vivaldi-stable is the alias (manifests/vendor-aliases.tsv); the resolved deb is staged,
# recorded and published by build/refresh-vendor-debs.sh, which verifies Vivaldi's signed
# Release + Release.gpg (build/vivaldi-apt-keyring.asc) -> Packages -> deb chain for amd64
# and arm64.
#
# Usage: build/refresh-vivaldi.sh [--check | --no-publish]
exec bash "$(dirname "$0")/refresh-vendor-debs.sh" "$@" vivaldi-stable
