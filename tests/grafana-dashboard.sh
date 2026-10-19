#!/bin/sh
# Lint examples/grafana-dashboard.json (make lint): run tests/grafana-dashboard.jq
# over it with what osxphotos-nas-mirror.sh writes, taken from the script
# itself so there is no third copy to keep in step:
# - the outcomes: the names in OUTCOMES.
# - the metric names: METRICS_PREFIX and each name the textfile writer
#   (metrics_text) passes to gauge or prints after the prefix.
set -eu
cd "$(dirname "$0")/.."
script=osxphotos-nas-mirror.sh
dashboard=examples/grafana-dashboard.json

outcomes=$(sed -n '/^OUTCOMES="/,/"$/p' "$script" | sed -e 's/^OUTCOMES=//' -e 's/"//g' |
    tr -s ' \t' '\n' | sed -n 's/^\([a-z-]*\):[0-9]*$/\1/p' | tr '\n' ' ')
prefix=$(sed -n 's/^METRICS_PREFIX=\([a-z_]*\)$/\1/p' "$script")
# shellcheck disable=SC2016 # ${METRICS_PREFIX} is text to match, not to expand.
metrics=$(sed -n '/^metrics_text() {/,/^}/p' "$script" |
    sed -n -e 's/.* gauge \([a-z_][a-z_]*\) .*/\1/p' \
        -e 's/.*%s\([a-z_][a-z_]*\)[ {].*/\1/p' \
        -e 's/.*\${METRICS_PREFIX}\([a-z_][a-z_]*\).*/\1/p' | sort -u | tr '\n' ' ')

for found in "outcomes:$outcomes" "prefix:$prefix" "metrics:$metrics"; do
    case "$found" in
        *: | *:' ')
            echo "tests/grafana-dashboard.sh: found no ${found%%:*} in $script" >&2
            exit 1
            ;;
    esac
done

jq -e --arg outcomes "$outcomes" --arg prefix "$prefix" --arg metrics "$metrics" \
    -f tests/grafana-dashboard.jq "$dashboard" > /dev/null
