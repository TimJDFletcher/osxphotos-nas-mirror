#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# network-path.sh -- an example preflight check for the mirror script: the
# run goes ahead only on a network that is neither expensive (a cellular
# connection or a personal hotspot) nor constrained (Low Data Mode), and is
# not offline.
#
# It runs network-path.swift, beside this file, which asks macOS for the
# current network path and prints one word: ok, expensive, constrained or
# no-network.
#
# Needs the Xcode command line tools (`xcode-select --install`) for swift.
# Without them the check exits 2 rather than run swift, because on a Mac
# lacking them xcrun pops up the install dialog.
# swift compiles the file on every run, and the first run takes the longest:
# up to 20 seconds on a cold cache, a few seconds after that. For a faster
# check, compile it once with `swiftc -O network-path.swift -o network-path`
# and set NETWORK_PATH_SWIFT to the binary.
#
# Usage: network-path.sh
#
# Exit 0: the path is ok, so the run goes ahead.
# Exit 1: the path is expensive, constrained or offline, so the run is
#         skipped. The line on stdout says which.
# Exit 2: the check itself broke: swift is missing, it crashed, it printed
#         nothing or something unexpected, or it did not finish in time.
#
# Environment variables, for tests and tuning:
#   NETWORK_PATH_SWIFT    the command that runs a Swift file, given the path
#                         of network-path.swift (default: xcrun swift)
#   NETWORK_PATH_SECONDS  seconds to wait before killing it (default: 60)
#   NETWORK_PATH_XCODE_SELECT  the xcode-select to ask whether the command
#                         line tools are installed (default: xcode-select).
#                         Asked only when NETWORK_PATH_SWIFT is unset.
#
# In the conf:
#   PREFLIGHT_CHECKS=("preflight-checks/network-path.sh")
#
# Written for macOS's stock /bin/sh and launchd's PATH: no timeout command,
# so a watchdog does the bounding.

name=network-path
swift_cmd=${NETWORK_PATH_SWIFT:-xcrun swift}
limit=${NETWORK_PATH_SECONDS:-60}
xcode_select=${NETWORK_PATH_XCODE_SELECT:-xcode-select}
here=$(cd "$(dirname "$0")" && pwd)

note() { printf '%s: %s\n' "$name" "$*"; }
fail() {
    note "$1"
    exit 2
}

if [ "$#" -ne 0 ]; then
    echo "Usage: $0" >&2
    exit 2
fi
case "$limit" in
    '' | *[!0-9]* | 0*) fail "NETWORK_PATH_SECONDS='$limit' is not a positive integer" ;;
esac

if [ -z "${NETWORK_PATH_SWIFT:-}" ]; then
    "$xcode_select" -p > /dev/null 2>&1 || fail "the Xcode command line tools are not installed"
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/network-path.XXXXXX") || fail "mktemp failed"
trap 'rm -rf "$tmp"' EXIT

# swift_cmd is a command plus arguments ("xcrun swift"), so it is split on
# purpose. It runs in the background with its stdout in a file; the loop
# kills it after $limit seconds.
# shellcheck disable=SC2086
$swift_cmd "$here/network-path.swift" > "$tmp/out" 2> "$tmp/err" &
pid=$!
waited=0
while kill -0 "$pid" 2> /dev/null; do
    if [ "$waited" -ge "$limit" ]; then
        kill "$pid" 2> /dev/null
        wait "$pid" 2> /dev/null
        fail "timed out after ${limit}s waiting for swift"
    fi
    sleep 1
    waited=$((waited + 1))
done
rc=0
wait "$pid" || rc=$?

# Whatever swift said on stderr is useful in the run log.
while IFS= read -r line; do
    note "swift: $line"
done < "$tmp/err"

[ "$rc" -eq 0 ] || fail "swift exited $rc"
word=$(cat "$tmp/out")
case "$word" in
    ok)
        note "ok"
        exit 0
        ;;
    expensive | constrained | no-network)
        note "$word, so skipping"
        exit 1
        ;;
    '') fail "swift printed nothing" ;;
    *) fail "swift printed something unexpected" ;;
esac
