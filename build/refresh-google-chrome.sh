#!/bin/bash
# refresh-google-chrome.sh -- move Google Chrome to the newest google-chrome-stable.
#
# google-chrome-stable is the alias (manifests/vendor-aliases.tsv); the resolved deb is staged,
# recorded and published by build/refresh-vendor-debs.sh, which verifies Google's signed
# InRelease (build/google-chrome-apt-keyring.asc) -> Packages -> deb chain for amd64 and arm64.
#
# Usage: build/refresh-google-chrome.sh [--check | --no-publish]
exec bash "$(dirname "$0")/refresh-vendor-debs.sh" "$@" google-chrome-stable
