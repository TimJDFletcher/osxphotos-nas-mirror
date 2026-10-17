#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# nas-rtt.sh HOST MAX_MS -- an example preflight check for the mirror
# script: the run goes ahead only when the NAS is close, for example on the
# home LAN. It pings HOST three times and compares the average round-trip
# time with MAX_MS milliseconds.
#
# A NAS that does not answer, or whose name does not resolve, counts as not
# close: that is what being away from home looks like. So that case skips the
# run quietly (exit 1) rather than reporting an error.
#
# Usage: nas-rtt.sh HOST MAX_MS      (MAX_MS a positive whole number)
#
# Exit 0: the average round trip is at most MAX_MS, so the run goes ahead.
# Exit 1: it is above MAX_MS, or HOST sent no reply (ping exits 2), or HOST
#         is unknown (ping exits 68), so the run is skipped.
# Exit 2: the check itself broke: bad arguments, ping failed for any other
#         reason, or its output could not be parsed.
#
# ping flags used: -c 3 (three packets), -t 5 (macOS ping: give up after 5
# seconds overall, so an unreachable NAS costs at most that).
#
# Environment variable, for tests:
#   NAS_RTT_PING  the ping command (default: /sbin/ping)
#
# In the conf:
#   PREFLIGHT_CHECKS=("preflight-checks/nas-rtt.sh nas.local 20")
#
# This check suits a NAS on the same LAN. For the iCloud side (the downlink
# the run's downloads of missing originals use), see download-speed.sh.
#
# Written for macOS's stock /bin/sh and launchd's PATH.

name=nas-rtt
ping_cmd=${NAS_RTT_PING:-/sbin/ping}

note() { printf '%s: %s\n' "$name" "$*"; }
fail() {
    note "$1"
    exit 2
}

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 HOST MAX_MS" >&2
    exit 2
fi
host=$1
max=$2
case "$host" in
    '' | -*) fail "HOST '$host' is empty or looks like an option" ;;
esac
case "$max" in
    '' | *[!0-9]* | 0*) fail "MAX_MS '$max' is not a positive integer" ;;
esac
[ "${#max}" -le 9 ] || fail "MAX_MS '$max' is out of range"

rc=0
output=$("$ping_cmd" -c 3 -t 5 "$host" 2>&1) || rc=$?
case "$rc" in
    0) ;;
    2)
        note "no reply from $host, so skipping"
        exit 1
        ;;
    68)
        note "unknown host $host, so skipping"
        exit 1
        ;;
    *) fail "ping exited $rc: $output" ;;
esac

# round-trip min/avg/max/stddev = 1.012/1.200/1.431/0.172 ms
avg=$(printf '%s\n' "$output" | sed -n 's|^round-trip min/avg/max/[a-z]* = [0-9.]*/\([0-9.]*\)/[0-9.]*/[0-9.]* ms$|\1|p' | head -n 1)
case "$avg" in
    '' | *[!0-9.]* | *.*.* | .) fail "could not read the average round trip from ping's output" ;;
esac

# The shell has no floating point; awk compares.
if awk -v a="$avg" -v m="$max" 'BEGIN { exit !(a + 0 <= m + 0) }'; then
    note "average round trip $avg ms, at most $max ms"
    exit 0
fi
note "average round trip $avg ms, above $max ms, so skipping"
exit 1
