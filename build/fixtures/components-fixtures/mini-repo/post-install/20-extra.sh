#!/bin/bash
# fixture hook: extra ncz-apt package
set -euo pipefail
DEBIAN_FRONTEND=noninteractive apt-get install -y ncz-widget
