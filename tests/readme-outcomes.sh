#!/bin/sh
# Lint the Outcomes table in README.md (make lint): its rows must be the
# outcomes in OUTCOMES in osxphotos-nas-mirror.sh, the same names with the
# same exit codes, none missing and none extra. A row looks like
# "| `name` | code | meaning |".
#
# POSIX sh only.
set -eu
cd "$(dirname "$0")/.."
readme=${README_FILE:-README.md}

want=$(tests/outcomes.sh | sort)
# shellcheck disable=SC2016 # The backticks are text to match, not a command.
have=$(sed -n '/^## Outcomes$/,/^## /p' "$readme" |
    sed -n 's/^| `\([a-z-]*\)` | \([0-9]*\) |.*/\1 \2/p' | sort)

if [ -z "$want" ] || [ -z "$have" ]; then
    echo "tests/readme-outcomes.sh: found no outcomes in OUTCOMES or in the Outcomes table of $readme" >&2
    exit 1
fi
if [ "$want" != "$have" ]; then
    echo "tests/readme-outcomes.sh: the Outcomes table in $readme differs from OUTCOMES (name exit code):" >&2
    printf 'OUTCOMES:\n%s\nREADME:\n%s\n' "$want" "$have" >&2
    exit 1
fi
