#!/bin/sh
# Print the outcomes in OUTCOMES in osxphotos-nas-mirror.sh, one "name code"
# line each, so the tests and lints have no copy of the set to keep in step.
# Run it, or capture it: tests/mirror-run.sh and tests/grafana-dashboard.sh do.
#
# POSIX sh only.
set -eu
script=$(dirname "$0")/../osxphotos-nas-mirror.sh
sed -n '/^OUTCOMES="/,/"$/p' "$script" | sed -e 's/^OUTCOMES=//' -e 's/"//g' |
    tr -s ' \t' '\n' | sed -n 's/^\([a-z-]*\):\([0-9]*\)\(:export-log\)\{0,1\}$/\1 \2/p'
