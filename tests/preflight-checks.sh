#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# tests/preflight-checks.sh -- fixture tests for the example preflight checks
# in preflight-checks/: network-path.sh, download-speed.sh and nas-rtt.sh. Each
# case runs a check as a process, in a clean environment, with a fake swift,
# networkQuality or ping that records its arguments and replays a fixture from
# tests/fixtures/. The real swift, networkQuality and ping are never run.
#
# The fakes are switched per case by environment variables:
#   FAKE_OUT    file the fake prints on stdout
#   FAKE_RC     the fake's exit code (default 0)
#   FAKE_SLEEP  the fake sleeps this many seconds instead (a hang)
# Each fake appends its arguments to $FAKE_DIR/calls.
#
# Run by `make test`. POSIX sh only.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
checks=$root/preflight-checks
fixtures=$root/tests/fixtures
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
count=0

# --- fakes

cat > "$work/swift" <<'STUB'
#!/bin/sh
echo "$*" >> "$FAKE_DIR/calls"
[ -z "${FAKE_SLEEP:-}" ] || exec sleep "$FAKE_SLEEP"
[ -z "${FAKE_OUT:-}" ] || cat "$FAKE_OUT"
echo "swift: some diagnostic" >&2
exit "${FAKE_RC:-0}"
STUB
cat > "$work/networkQuality" <<'STUB'
#!/bin/sh
echo "$*" >> "$FAKE_DIR/calls"
# Refuse what the real one refuses: no -c, no -u (download only), no numeric -M.
case " $* " in *" -c "*) ;; *) echo "fake: -c missing" >&2; exit 2 ;; esac
case " $* " in *" -u "*) ;; *) echo "fake: -u missing" >&2; exit 2 ;; esac
case "$*" in *"-M "[0-9]*) ;; *) echo "fake: -M needs a number" >&2; exit 2 ;; esac
[ -z "${FAKE_SLEEP:-}" ] || exec sleep "$FAKE_SLEEP"
[ -z "${FAKE_OUT:-}" ] || cat "$FAKE_OUT"
exit "${FAKE_RC:-0}"
STUB
cat > "$work/ping" <<'STUB'
#!/bin/sh
echo "$*" >> "$FAKE_DIR/calls"
[ -z "${FAKE_OUT:-}" ] || cat "$FAKE_OUT"
exit "${FAKE_RC:-0}"
STUB
cat > "$work/xcode-select-fails" <<'STUB'
#!/bin/sh
echo "$*" >> "$FAKE_DIR/calls"
echo "xcode-select: error: unable to get active developer directory" >&2
exit 2
STUB
chmod +x "$work/xcode-select-fails"
chmod +x "$work/swift" "$work/networkQuality" "$work/ping"
mkdir -p "$work/empty"
: > "$work/empty.txt"
printf 'this is not what ping prints\n' > "$work/garbage.txt"
printf 'sideways\n' > "$work/word-garbage.txt"
printf 'ok\nextra\n' > "$work/word-two-lines.txt"
printf 'expensive\n' > "$work/word-expensive.txt"
printf 'constrained\n' > "$work/word-constrained.txt"
printf 'no-network\n' > "$work/word-no-network.txt"
printf 'ok\n' > "$work/word-ok.txt"
printf '{ "ul_throughput" : 5 }\n' > "$work/nq-no-field.json"
printf '{\n  "dl_throughput" : 0\n}\n' > "$work/nq-zero.json"
printf '{\n  "dl_throughput" : "fast"\n}\n' > "$work/nq-string.json"
printf '{\n  "dl_throughput" : 5.2e7\n}\n' > "$work/nq-exp.json"
printf '{\n  "dl_throughput" : 99999999999999999999\n}\n' > "$work/nq-huge.json"
printf 'round-trip min/avg/max/stddev = 19.000/20.000/21.000/1.000 ms\n' > "$work/ping-20.txt"
printf 'round-trip min/avg/max/stddev = 19.000/20.001/21.000/1.000 ms\n' > "$work/ping-20-001.txt"
printf 'round-trip min/avg/max/stddev = a/b/c/d ms\n' > "$work/ping-nonnumeric.txt"

# --- harness

# run_check CHECK [VAR=value ...] -- [args...]: run a check in a clean
# environment. Sets rc, out (stdout and stderr together) and calls.
run_check() {
    name=$1
    shift
    : > "$work/calls"
    envs=
    while [ "$1" != "--" ]; do
        envs="$envs $1"
        shift
    done
    shift
    rc=0
    # shellcheck disable=SC2086 # envs is a list of VAR=value words without spaces
    out=$(env -i PATH="/usr/bin:/bin" TMPDIR="$work" FAKE_DIR="$work" $envs \
        /bin/sh "$checks/$name" "$@" 2>&1) || rc=$?
    calls=$(cat "$work/calls")
}

check() {
    count=$((count + 1))
    if [ "$1" = "$2" ]; then
        echo "ok $count - $3"
    else
        echo "not ok $count - $3 (got '$1', want '$2')"
        failures=$((failures + 1))
    fi
}

# contains TEXT SUBSTRING: prints yes or no.
contains() {
    case "$1" in
        *"$2"*) echo yes ;;
        *) echo no ;;
    esac
}

# --- network-path.sh

np="NETWORK_PATH_SWIFT=$work/swift"

run_check network-path.sh "$np" "FAKE_OUT=$work/word-ok.txt" --
check "$rc" 0 "network-path: ok exits 0"
check "$calls" "$checks/network-path.swift" "network-path: the swift fake is given the .swift file beside the check"
check "$(contains "$out" "network-path:")" yes "network-path: output is prefixed with the check's name"

for w in expensive constrained no-network; do
    run_check network-path.sh "$np" "FAKE_OUT=$work/word-$w.txt" --
    check "$rc" 1 "network-path: $w exits 1"
    check "$(contains "$out" "network-path: $w")" yes "network-path: $w says which"
done

run_check network-path.sh "$np" "FAKE_OUT=$work/word-garbage.txt" --
check "$rc" 2 "network-path: an unknown word exits 2"
run_check network-path.sh "$np" "FAKE_OUT=$work/word-two-lines.txt" --
check "$rc" 2 "network-path: ok plus an extra line exits 2"
run_check network-path.sh "$np" "FAKE_OUT=$work/empty.txt" --
check "$rc" 2 "network-path: no output exits 2"
run_check network-path.sh "$np" "FAKE_OUT=$work/word-ok.txt" FAKE_RC=1 --
check "$rc" 2 "network-path: a crash exits 2 even if it printed ok"
run_check network-path.sh "NETWORK_PATH_SWIFT=$work/does-not-exist" --
check "$rc" 2 "network-path: a missing swift exits 2"
check "$(contains "$out" "network-path:")" yes "network-path: a missing swift says so"

start=$(date +%s)
run_check network-path.sh "$np" FAKE_SLEEP=30 NETWORK_PATH_SECONDS=1 --
elapsed=$(($(date +%s) - start))
check "$rc" 2 "network-path: a hung swift is killed and exits 2"
check "$([ "$elapsed" -lt 10 ] && echo yes || echo no)" yes "network-path: the hung swift was killed within the bound (${elapsed}s)"
check "$(contains "$out" "timed out")" yes "network-path: a hang says it timed out"

run_check network-path.sh "$np" NETWORK_PATH_SECONDS=0 --
check "$rc" 2 "network-path: a bound that is not a positive integer exits 2"

# With the default swift, a Mac without the command line tools must not run
# it: xcrun would pop the install dialog. The fake xcode-select fails, so the
# real swift is never reached.
run_check network-path.sh "NETWORK_PATH_XCODE_SELECT=$work/xcode-select-fails" --
check "$rc" 2 "network-path: no command line tools exits 2"
check "$(contains "$out" "command line tools are not installed")" yes \
    "network-path: no command line tools says so"
check "$calls" "-p" "network-path: xcode-select is asked with -p"

# --- download-speed.sh

us="DOWNLOAD_SPEED_NETWORKQUALITY=$work/networkQuality"
nqfix=$fixtures/networkQuality-download.json

run_check download-speed.sh "$us" "FAKE_OUT=$nqfix" -- 50
check "$rc" 0 "download-speed: 87.2 Mbit/s against a minimum of 50 exits 0"
check "$calls" "-c -u -M 30" "download-speed: networkQuality gets -c -u (download only) and -M 30"
check "$(contains "$out" "download-speed: ")" yes "download-speed: output is prefixed with the check's name"
check "$(contains "$out" "87181864")" yes "download-speed: the measured rate is logged"
run_check download-speed.sh "$us" "FAKE_OUT=$nqfix" -- 87
check "$rc" 0 "download-speed: a minimum of 87 is met"
run_check download-speed.sh "$us" "FAKE_OUT=$nqfix" -- 88
check "$rc" 1 "download-speed: a minimum of 88 is not met: exits 1"
check "$(contains "$out" "below")" yes "download-speed: a slow link says it is below the minimum"

run_check download-speed.sh "$us" "FAKE_OUT=$nqfix" DOWNLOAD_SPEED_SECONDS=9 -- 10
check "$calls" "-c -u -M 9" "download-speed: DOWNLOAD_SPEED_SECONDS sets -M"

for bad in 0 -5 abc 1.5 010 "" "5 6"; do
    run_check download-speed.sh "$us" "FAKE_OUT=$nqfix" -- "$bad"
    check "$rc" 2 "download-speed: MIN_MBIT '$bad' exits 2"
    check "$calls" "" "download-speed: MIN_MBIT '$bad' runs nothing"
done
run_check download-speed.sh "$us" "FAKE_OUT=$nqfix" --
check "$rc" 2 "download-speed: no MIN_MBIT exits 2"
run_check download-speed.sh "$us" "FAKE_OUT=$nqfix" -- 10 20
check "$rc" 2 "download-speed: two arguments exit 2"
run_check download-speed.sh "$us" "FAKE_OUT=$nqfix" DOWNLOAD_SPEED_SECONDS=0 -- 10
check "$rc" 2 "download-speed: DOWNLOAD_SPEED_SECONDS=0 exits 2"

run_check download-speed.sh "$us" "FAKE_OUT=$nqfix" FAKE_RC=1 -- 10
check "$rc" 2 "download-speed: networkQuality failing exits 2"
for f in nq-no-field nq-zero nq-string nq-exp nq-huge; do
    run_check download-speed.sh "$us" "FAKE_OUT=$work/$f.json" -- 1
    check "$rc" 2 "download-speed: $f output exits 2"
done
run_check download-speed.sh "$us" "FAKE_OUT=$work/empty.txt" -- 1
check "$rc" 2 "download-speed: empty output exits 2"
run_check download-speed.sh "DOWNLOAD_SPEED_NETWORKQUALITY=$work/does-not-exist" -- 1
check "$rc" 2 "download-speed: a missing networkQuality exits 2"

start=$(date +%s)
run_check download-speed.sh "$us" FAKE_SLEEP=30 DOWNLOAD_SPEED_SECONDS=1 DOWNLOAD_SPEED_GRACE=1 -- 10
elapsed=$(($(date +%s) - start))
check "$rc" 2 "download-speed: a hung networkQuality is killed and exits 2"
check "$([ "$elapsed" -lt 10 ] && echo yes || echo no)" yes "download-speed: the hung networkQuality was killed within the bound (${elapsed}s)"
check "$(contains "$out" "timed out")" yes "download-speed: a hang says it timed out"

# --- nas-rtt.sh

nr="NAS_RTT_PING=$work/ping"

run_check nas-rtt.sh "$nr" "FAKE_OUT=$fixtures/ping-answered.txt" -- nas.example 5
check "$rc" 0 "nas-rtt: an average of 1.2 ms against a maximum of 5 exits 0"
check "$calls" "-c 3 -t 5 nas.example" "nas-rtt: ping gets -c 3 -t 5 and the host"
check "$(contains "$out" "nas-rtt: ")" yes "nas-rtt: output is prefixed with the check's name"
run_check nas-rtt.sh "$nr" "FAKE_OUT=$fixtures/ping-answered.txt" -- nas.example 1
check "$rc" 1 "nas-rtt: an average of 1.2 ms against a maximum of 1 exits 1"
check "$(contains "$out" "above")" yes "nas-rtt: a slow answer says it is above the maximum"
run_check nas-rtt.sh "$nr" "FAKE_OUT=$work/ping-20.txt" -- nas.example 20
check "$rc" 0 "nas-rtt: an average equal to the maximum exits 0"
run_check nas-rtt.sh "$nr" "FAKE_OUT=$work/ping-20-001.txt" -- nas.example 20
check "$rc" 1 "nas-rtt: an average just above the maximum exits 1"

run_check nas-rtt.sh "$nr" "FAKE_OUT=$fixtures/ping-no-reply.txt" FAKE_RC=2 -- 192.0.2.99 20
check "$rc" 1 "nas-rtt: no reply (ping exit 2) exits 1"
check "$(contains "$out" "no reply")" yes "nas-rtt: no reply says so"
run_check nas-rtt.sh "$nr" "FAKE_OUT=$fixtures/ping-unknown-host.txt" FAKE_RC=68 -- nas.invalid 20
check "$rc" 1 "nas-rtt: an unknown host (ping exit 68) exits 1"
check "$(contains "$out" "unknown host")" yes "nas-rtt: an unknown host says so"
run_check nas-rtt.sh "$nr" "FAKE_OUT=$work/empty.txt" FAKE_RC=64 -- nas.example 20
check "$rc" 2 "nas-rtt: ping failing for another reason (exit 64) exits 2"

run_check nas-rtt.sh "$nr" "FAKE_OUT=$work/garbage.txt" -- nas.example 20
check "$rc" 2 "nas-rtt: unparseable ping output exits 2"
run_check nas-rtt.sh "$nr" "FAKE_OUT=$work/ping-nonnumeric.txt" -- nas.example 20
check "$rc" 2 "nas-rtt: a non-numeric average exits 2"
run_check nas-rtt.sh "$nr" "FAKE_OUT=$work/empty.txt" -- nas.example 20
check "$rc" 2 "nas-rtt: ping succeeding with no output exits 2"
run_check nas-rtt.sh "NAS_RTT_PING=$work/does-not-exist" -- nas.example 20
check "$rc" 2 "nas-rtt: a missing ping exits 2"

for bad in 0 -5 abc 1.5 010 ""; do
    run_check nas-rtt.sh "$nr" "FAKE_OUT=$fixtures/ping-answered.txt" -- nas.example "$bad"
    check "$rc" 2 "nas-rtt: MAX_MS '$bad' exits 2"
    check "$calls" "" "nas-rtt: MAX_MS '$bad' runs nothing"
done
run_check nas-rtt.sh "$nr" "FAKE_OUT=$fixtures/ping-answered.txt" -- "" 20
check "$rc" 2 "nas-rtt: an empty HOST exits 2"
run_check nas-rtt.sh "$nr" "FAKE_OUT=$fixtures/ping-answered.txt" -- -nas 20
check "$rc" 2 "nas-rtt: a HOST that looks like an option exits 2"
run_check nas-rtt.sh "$nr" "FAKE_OUT=$fixtures/ping-answered.txt" -- nas.example
check "$rc" 2 "nas-rtt: one argument exits 2"
run_check nas-rtt.sh "$nr" "FAKE_OUT=$fixtures/ping-answered.txt" --
check "$rc" 2 "nas-rtt: no arguments exits 2"
run_check nas-rtt.sh "$nr" "FAKE_OUT=$fixtures/ping-answered.txt" -- nas.example 20 extra
check "$rc" 2 "nas-rtt: three arguments exit 2"

if [ "$failures" -ne 0 ]; then
    echo "$failures of $count checks failed"
    exit 1
fi
echo "all $count checks passed"
