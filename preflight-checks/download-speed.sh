#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# download-speed.sh MIN_MBIT -- an example preflight check for the mirror
# script: the run goes ahead only if this Mac's download speed is at least
# MIN_MBIT megabits per second.
#
# The run downloads missing originals from iCloud (osxphotos's
# download_missing: photos whose originals are only in iCloud are fetched
# during the export), so on a slow downlink it crawls. This check makes the
# run wait for a fast enough one.
#
# It measures with macOS's networkQuality, download half only, and reads
# dl_throughput (bits per second) from its JSON output. networkQuality
# measures the path to Apple's servers, which is where those iCloud downloads
# come from. The share's own speed is a different question; for a NAS on the
# LAN, nas-rtt.sh answers it.
#
# The test downloads for several seconds and uses real bandwidth, so it adds
# up to DOWNLOAD_SPEED_SECONDS to every run.
#
# Usage: download-speed.sh MIN_MBIT    (a positive whole number, 1 Mbit = 10^6 bit)
#
# Exit 0: the download speed is at least MIN_MBIT, so the run goes ahead.
# Exit 1: it is below, so the run is skipped.
# Exit 2: the check itself broke: MIN_MBIT is not a positive integer, or
#         networkQuality failed, timed out, or printed no usable dl_throughput.
#
# Environment variables, for tests and tuning:
#   DOWNLOAD_SPEED_NETWORKQUALITY  the networkQuality command
#                                  (default: /usr/bin/networkQuality)
#   DOWNLOAD_SPEED_SECONDS         networkQuality's -M bound (default: 30)
#   DOWNLOAD_SPEED_GRACE           extra seconds before a networkQuality that
#                                  hung past -M is killed (default: 10)
#
# networkQuality flags used: -c (JSON on stdout), -u (no upload test, so
# download only), -M SECONDS (maximum runtime).
#
# In the conf:
#   PREFLIGHT_CHECKS=("preflight-checks/download-speed.sh 50")
#
# Written for macOS's stock /bin/sh and launchd's PATH: no jq and no timeout
# command, so the one JSON field is read with sed and a watchdog does the
# bounding.

name=download-speed
nq=${DOWNLOAD_SPEED_NETWORKQUALITY:-/usr/bin/networkQuality}
seconds=${DOWNLOAD_SPEED_SECONDS:-30}
grace=${DOWNLOAD_SPEED_GRACE:-10}

note() { printf '%s: %s\n' "$name" "$*"; }
fail() {
    note "$1"
    exit 2
}

# A positive integer without a leading zero, short enough for shell
# arithmetic.
posint() {
    case "$1" in
        '' | *[!0-9]* | 0*) return 1 ;;
    esac
    [ "${#1}" -le 9 ]
}

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 MIN_MBIT" >&2
    exit 2
fi
min=$1
posint "$min" || fail "MIN_MBIT '$min' is not a positive integer"
posint "$seconds" || fail "DOWNLOAD_SPEED_SECONDS='$seconds' is not a positive integer"
posint "$grace" || fail "DOWNLOAD_SPEED_GRACE='$grace' is not a positive integer"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/download-speed.XXXXXX") || fail "mktemp failed"
trap 'rm -rf "$tmp"' EXIT

# -M bounds networkQuality itself; the watchdog is for a hang past that.
bound=$((seconds + grace))
"$nq" -c -u -M "$seconds" > "$tmp/out" 2> "$tmp/err" &
pid=$!
waited=0
while kill -0 "$pid" 2> /dev/null; do
    if [ "$waited" -ge "$bound" ]; then
        kill "$pid" 2> /dev/null
        wait "$pid" 2> /dev/null
        fail "timed out: networkQuality still running after ${bound}s, killed"
    fi
    sleep 1
    waited=$((waited + 1))
done
rc=0
wait "$pid" || rc=$?

while IFS= read -r line; do
    note "networkQuality: $line"
done < "$tmp/err"
[ "$rc" -eq 0 ] || fail "networkQuality exited $rc"

# "dl_throughput" : 52935092,   (bits per second, an integer)
bits=$(sed -n 's/^[[:space:]]*"dl_throughput"[[:space:]]*:[[:space:]]*\([^,[:space:]]*\).*$/\1/p' "$tmp/out" | head -n 1)
[ -n "$bits" ] || fail "no dl_throughput in networkQuality's output"
case "$bits" in
    *[!0-9]*) fail "dl_throughput '$bits' is not an integer" ;;
esac
[ "${#bits}" -le 12 ] || fail "dl_throughput '$bits' is out of range"
case "$bits" in
    0*) fail "dl_throughput '$bits' is zero or has a leading zero" ;;
esac

need=$((min * 1000000))
if [ "$bits" -ge "$need" ]; then
    note "download $bits bit/s, at least $min Mbit/s"
    exit 0
fi
note "download $bits bit/s, below $min Mbit/s, so skipping"
exit 1
