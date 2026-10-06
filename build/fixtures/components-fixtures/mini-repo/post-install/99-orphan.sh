#!/bin/bash
# fixture hook: the file exists on disk but is listed in no hooks.list.*
# file. test-components.sh uses it to prove that a required row naming a
# second, never-run installer is still caught (hook-never-runs).
set -euo pipefail
true
