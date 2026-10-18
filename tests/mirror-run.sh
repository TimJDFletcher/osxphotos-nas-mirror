#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# tests/mirror-run.sh -- fixture tests for osxphotos-nas-mirror.sh. The real
# dock, share and Photos library are never used. Each case runs the script as
# a process with a test conf (OSXPHOTOS_NAS_MIRROR_CONF) and stub mount, uvx
# (for osxphotos), osascript (for notifications and mounting) and security
# first on PATH. The test conf's PREFLIGHT_CHECKS holds stub check scripts in
# the case's directory. The example dock check is run as a process too, with
# a stub ifconfig. Stub behaviour is switched per case by marker files in the
# case's directory ($FAKE_DIR).
#
# Run by `make test`. With VERBOSE=1 every case prints the run's log.
#
# POSIX sh only.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
script=$root/osxphotos-nas-mirror.sh
work=$(mktemp -d)
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT
failures=0
count=0

dock_mac=aa:bb:cc:dd:ee:ff

# stubs
mkdir -p "$work/bin"
cat > "$work/bin/ifconfig" <<STUB
#!/bin/sh
echo "en0: flags=8863<UP,BROADCAST,RUNNING>"
echo "	ether 11:22:33:44:55:66"
if [ ! -e "\$FAKE_DIR/undocked" ]; then
    echo "en7: flags=8863<UP,BROADCAST,RUNNING>"
    echo "	ether $dock_mac"
fi
STUB
cat > "$work/bin/mount" <<'STUB'
#!/bin/sh
echo "/dev/disk3s1 on / (apfs, local)"
[ ! -e "$FAKE_DIR/mounts" ] || cat "$FAKE_DIR/mounts"
STUB
# A bare osxphotos must never run from a test: the real one reads the real
# Photos library. The script runs it through uvx, stubbed below.
cat > "$work/bin/osxphotos" <<'STUB'
#!/bin/sh
echo "tests: the script ran osxphotos directly, not through uvx" >&2
exit 99
STUB
# uvx: the script runs osxphotos through uv, so this stub stands in for both.
# It prints what osxphotos export prints with verbose = true to a file (not a
# terminal): a line or two per photo, then the closing summary and cleanup
# lines, as osxphotos/cli/export.py at the pinned tag writes them through
# rich with the markup stripped. A failed or stopped export prints no summary.
cat > "$work/bin/uvx" <<'STUB'
#!/bin/sh
for a in "$@"; do printf '%s\n' "$a"; done > "$FAKE_DIR/uvx-args.log"
echo called >> "$FAKE_DIR/uvx-calls.log"
db=
for a in "$@"; do dest=$a; done
while [ $# -gt 0 ]; do
    if [ "$1" = --exportdb ]; then db=$2; fi
    shift
done
echo "Exporting 3 photos to $dest..."
for n in 1 2 3; do
    echo "Exporting IMG_000$n.HEIC (IMG_000$n.HEIC) ($n/3)"
done
echo "Exported new file $dest/2026/10/18/IMG_0001.HEIC"
echo "Exported updated file $dest/2026/10/18/IMG_0002.HEIC"
if [ -e "$FAKE_DIR/export-fails" ]; then echo "osxphotos: export failed" >&2; exit 1; fi
[ -z "$db" ] || echo "fake export db" > "$db"
# export-runs: a long export. It writes its pid to export.pid and runs until
# the case creates export-stop (at most 30 seconds).
if [ -e "$FAKE_DIR/export-runs" ]; then
    echo $$ > "$FAKE_DIR/export.pid"
    i=0
    while [ ! -e "$FAKE_DIR/export-stop" ] && [ "$i" -lt 150 ]; do sleep 0.2; i=$((i + 1)); done
fi
# share-drops: the share goes partway through, and the export carries on
# (as osxphotos did, into the folder left behind) until it is stopped.
if [ -e "$FAKE_DIR/share-drops" ]; then
    : > "$FAKE_DIR/mounts"
    i=0
    while [ "$i" -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
    : > "$FAKE_DIR/export-finished"
fi
# share-drops-at-end: the share goes just as the export finishes.
[ ! -e "$FAKE_DIR/share-drops-at-end" ] || : > "$FAKE_DIR/mounts"
# no-summary: an export that ends without its summary.
[ ! -e "$FAKE_DIR/no-summary" ] || exit 0
echo "Processed: 3 photos, exported: 1, updated: 1, skipped: 1, updated EXIF data: 0, missing: 0, error: 0, touched date: 2"
echo "Elapsed time: 0:00:01"
echo "Cleaning up $dest"
echo "Deleting $dest/2026/10/17/IMG_0000.HEIC"
echo "Deleted: 1 file, 0 directories"
STUB
# osascript: a script that mounts a volume stands in for Finder's mount,
# under the case's own Volumes directory; anything else is a notification.
cat > "$work/bin/osascript" <<'STUB'
#!/bin/sh
case "$*" in
    *"mount volume"*)
        for a in "$@"; do url=$a; done
        printf '%s\n' "$url" >> "$FAKE_DIR/mount-volume-args.log"
        if [ -e "$FAKE_DIR/mount-fails" ]; then echo "execution error: The server could not be found. (-1426)" >&2; exit 1; fi
        if [ -e "$FAKE_DIR/mount-hangs" ]; then sleep 30; fi
        mkdir -p "$FAKE_DIR/Volumes/photos"
        echo "${url#smb:} on $FAKE_DIR/Volumes/photos (smbfs, nodev, nosuid, mounted by tim)" >> "$FAKE_DIR/mounts"
        [ ! -e "$FAKE_DIR/share-readonly" ] || chmod a-w "$FAKE_DIR/Volumes/photos"
        echo "file photos:"
        exit 0
        ;;
esac
for a in "$@"; do printf '%s\n' "$a"; done >> "$FAKE_DIR/osascript-args.log"
if [ -e "$FAKE_DIR/notify-fails" ]; then echo "osascript: execution error" >&2; exit 1; fi
if [ -e "$FAKE_DIR/notify-hangs" ]; then sleep 30; fi
STUB
cat > "$work/bin/security" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_DIR/security-args.log"
case "$1" in
    find-internet-password)
        if [ -e "$FAKE_DIR/no-keychain" ]; then
            echo "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain." >&2
            exit 44
        fi
        ;;
esac
STUB
chmod +x "$work/bin/"*

# setup NAME: make a case directory with a conf. Sets $fake.
setup() {
    fake=$work/$1
    mkdir -p "$fake"
    # The stub preflight check records its arguments and exits with the code in
    # preflight-check-exit (default 0).
    cat > "$fake/preflight-check.sh" <<'CHECK'
#!/bin/sh
printf '%s\n' "$@" > "$FAKE_DIR/preflight-check-args.log"
exit "$(cat "$FAKE_DIR/preflight-check-exit" 2> /dev/null || echo 0)"
CHECK
    chmod +x "$fake/preflight-check.sh"
    cat > "$fake/test.conf" <<CONF
NAS_USER="tim"
NAS_HOSTNAME="nas.test"
NAS_SHARE="photos"
PREFLIGHT_CHECKS=("$fake/preflight-check.sh an-argument")
APP_DIR="$fake/app"
LOG_FILE="$fake/app/osxphotos-nas-mirror.log"
OSXPHOTOS_EXPORT_DB="$fake/app/osxphotos_export.db"
LOCK_FILE="$fake/run.lock"
NOTIFY_TIMEOUT=1
MOUNT_TIMEOUT=1
SHARE_CHECK_INTERVAL=1
CONF
}

# run [ARGS...]: run the script for the current case. Sets $rc and $log.
# HOME points into the case too, so a script that ignored the conf override
# and read the real conf would still write nowhere real. With
# conf_override=none the override is left unset, so the script reads its
# default conf, under the case's HOME.
run() {
    rc=0
    mkdir -p "$fake/home"
    if [ "${conf_override:-}" = none ]; then
        set -- env -u OSXPHOTOS_NAS_MIRROR_CONF "$script" "$@"
    else
        set -- env OSXPHOTOS_NAS_MIRROR_CONF="$fake/test.conf" "$script" "$@"
    fi
    env HOME="$fake/home" PATH="$work/bin:$PATH" FAKE_DIR="$fake" \
        "$@" > "$fake/stdout" 2> "$fake/stderr" || rc=$?
    log=$(cat "$fake/app/osxphotos-nas-mirror.log" 2>/dev/null || true)
    if [ -n "${VERBOSE:-}" ]; then
        echo "--- $fake"; cat "$fake/stdout" "$fake/stderr"
    fi
}

# start_run: start the script for the current case in the
# background, as run does. Sets $run_pid (env execs the script, so it is the
# script's own pid).
start_run() {
    mkdir -p "$fake/home"
    env HOME="$fake/home" PATH="$work/bin:$PATH" FAKE_DIR="$fake" \
        OSXPHOTOS_NAS_MIRROR_CONF="$fake/test.conf" \
        "$script" > "$fake/stdout" 2> "$fake/stderr" &
    run_pid=$!
}

# wait_for FILE: wait up to 10 seconds for FILE to appear.
wait_for() {
    i=0
    while [ ! -e "$1" ] && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
}

# wait_gone PID: wait up to 10 seconds for process PID to go.
wait_gone() {
    i=0
    while kill -0 "$1" 2> /dev/null && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
}

# alive PID: "alive" if process PID is running, else "gone".
alive() {
    if kill -0 "$1" 2> /dev/null; then echo alive; else echo gone; fi
}

# hold_lock FILE: take the run lock on FILE as another run would, from a
# process that holds it for 10 seconds or until killed. Sets $holder.
hold_lock() {
    rm -f "$fake/lock-held"
    perl -MFcntl=:flock -e 'open(my $fh, ">>", $ARGV[0]) or exit 2;
        flock($fh, LOCK_EX) or exit 2; open(my $m, ">", $ARGV[1]); close $m; sleep 10' \
        "$1" "$fake/lock-held" &
    holder=$!
    wait_for "$fake/lock-held"
}

# called STUB...: "called" if any of the stubs ran in this case, else "none".
# (A stub leaves STUB-args.log in the case directory.)
called() {
    for stub in "$@"; do
        if [ -e "$fake/$stub-args.log" ]; then echo called; return; fi
    done
    echo none
}

# notified OUTCOME: "yes" if this case posted one notification naming OUTCOME.
notified() {
    if [ "$(grep -c "Mirror run failed: $1\." "$fake/osascript-args.log" 2>/dev/null)" = 1 ]; then
        echo yes
    else
        echo no
    fi
}

outcome() {
    printf '%s\n' "$log" | tail -n 1 | sed -n 's/.*outcome=//p'
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

# --- cases

setup ok
run
check "$rc" 0 "plain run exits 0"
check "$(outcome)" ok "plain run ends with outcome=ok"
check "$(called osascript)" none "plain run posts no notification"
check "$(cat "$fake/Volumes/photos/.osxphotos_export.db" 2>/dev/null)" "fake export db" \
    "plain run copies the export database to the share"
want_args=$(printf '%s\n' --python 3.13 \
    --from git+https://github.com/TimJDFletcher/osxphotos@v0.77.2-tim.3 osxphotos export --newest-first --load-config "$root/osxphotos.toml" \
    --exportdb "$fake/app/osxphotos_export.db" "$fake/Volumes/photos")
check "$(cat "$fake/uvx-args.log")" "$want_args" \
    "plain run exports with our fork's osxphotos, newest first, with the repo's config and the local export database, to the share"
check "$(cat "$fake/mount-volume-args.log")" "smb://tim@nas.test/photos" \
    "plain run mounts the share as Finder does"

# Run by a relative path from another directory, the script must still find
# its own directory, where osxphotos.toml is.
setup relative-invocation
rc=0
mkdir -p "$fake/home"
(
    cd "$root/.." && env HOME="$fake/home" PATH="$work/bin:$PATH" FAKE_DIR="$fake" \
        OSXPHOTOS_NAS_MIRROR_CONF="$fake/test.conf" \
        bash "$(basename "$root")/osxphotos-nas-mirror.sh" > "$fake/stdout" 2> "$fake/stderr"
) || rc=$?
log=$(cat "$fake/app/osxphotos-nas-mirror.log" 2> /dev/null || true)
check "$(outcome)" ok "a run started by a relative path from another directory ends with an outcome"
check "$(sed -n '/^--load-config$/{n;p;}' "$fake/uvx-args.log")" "$root/osxphotos.toml" \
    "a run started by a relative path finds the repo's osxphotos.toml"

# A bare $0 (no "/"): dirname gives ".".
setup bare-invocation
rc=0
mkdir -p "$fake/home"
(
    cd "$root" && env HOME="$fake/home" PATH="$work/bin:$PATH" FAKE_DIR="$fake" \
        OSXPHOTOS_NAS_MIRROR_CONF="$fake/test.conf" \
        bash osxphotos-nas-mirror.sh > "$fake/stdout" 2> "$fake/stderr"
) || rc=$?
log=$(cat "$fake/app/osxphotos-nas-mirror.log" 2> /dev/null || true)
check "$(outcome)" ok "a run started by a bare script name ends with an outcome"
check "$(sed -n '/^--load-config$/{n;p;}' "$fake/uvx-args.log")" "$root/osxphotos.toml" \
    "a run started by a bare script name finds the repo's osxphotos.toml"

setup osxphotos-source
echo 'OSXPHOTOS_SOURCE="osxphotos==0.77.2"' >> "$fake/test.conf"
run
check "$(sed -n '/^--from$/{n;p;}' "$fake/uvx-args.log")" "osxphotos==0.77.2" \
    "OSXPHOTOS_SOURCE in the conf is what uvx runs osxphotos from"

setup osxphotos-config
echo 'OSXPHOTOS_CONFIG="/elsewhere/my-osxphotos.toml"' >> "$fake/test.conf"
run
check "$(sed -n '/^--load-config$/{n;p;}' "$fake/uvx-args.log")" "/elsewhere/my-osxphotos.toml" \
    "OSXPHOTOS_CONFIG in the conf is the osxphotos config the export loads"

# With no override, the conf is the one in the app directory under HOME.
setup default-conf
mkdir -p "$fake/home/Library/Application Support/osxphotos-nas-mirror"
cp "$fake/test.conf" "$fake/home/Library/Application Support/osxphotos-nas-mirror/osxphotos-nas-mirror.conf"
conf_override=none
run
conf_override=
check "$(outcome)" ok "with no conf override, the run reads the conf in the app directory"

setup preflight-check-passes
run
check "$(cat "$fake/preflight-check-args.log")" "an-argument" \
    "the preflight check is run with the arguments the conf gives it"
check "$(outcome)" ok "a run whose preflight check exits 0 goes ahead"

setup no-preflight-check
grep -v '^PREFLIGHT_CHECKS=' "$fake/test.conf" > "$fake/trimmed.conf"
mv "$fake/trimmed.conf" "$fake/test.conf"
run
check "$(outcome)" ok "a conf with no PREFLIGHT_CHECKS goes ahead"

setup empty-preflight-check
echo 'PREFLIGHT_CHECKS=()' >> "$fake/test.conf"
run
check "$(outcome)" ok "an empty PREFLIGHT_CHECKS goes ahead"
check "$(called preflight-check)" none "an empty PREFLIGHT_CHECKS runs no command"

# Several checks, run in order. The second is a copy of the stub that records
# to its own files: second-check-args.log and second-check-exit.
add_second_check() {
    cat > "$fake/second-check.sh" <<'CHECK'
#!/bin/sh
printf '%s\n' "$@" > "$FAKE_DIR/second-check-args.log"
exit "$(cat "$FAKE_DIR/second-check-exit" 2> /dev/null || echo 0)"
CHECK
    chmod +x "$fake/second-check.sh"
    grep -v '^PREFLIGHT_CHECKS=' "$fake/test.conf" > "$fake/trimmed.conf"
    mv "$fake/trimmed.conf" "$fake/test.conf"
    echo 'PREFLIGHT_CHECKS=("'"$fake"'/preflight-check.sh first-arg" "'"$fake"'/second-check.sh second-arg other-arg")' >> "$fake/test.conf"
}

setup two-checks-pass
add_second_check
run
check "$(outcome)" ok "two preflight checks that both exit 0 let the run go ahead"
check "$(cat "$fake/preflight-check-args.log")" "first-arg" "the first of two checks gets its own arguments"
check "$(cat "$fake/second-check-args.log")" "$(printf '%s\n' second-arg other-arg)" \
    "the second of two checks gets all of its arguments"

setup first-check-skips
add_second_check
echo 1 > "$fake/preflight-check-exit"
run
check "$(outcome)" skipped-preflight-check "a first check that exits 1 ends the run skipped-preflight-check"
check "$(called second-check)" none "a first check that exits 1 stops the second from running"
check "$(grep -c 'preflight-check.sh first-arg exited 1' "$fake/app/osxphotos-nas-mirror.log")" 1 \
    "the log names the first check as the one that decided"

setup first-check-fails
add_second_check
echo 2 > "$fake/preflight-check-exit"
run
check "$(outcome)" preflight-check-failed "a first check that exits 2 ends the run preflight-check-failed"
check "$(called second-check)" none "a first check that exits 2 stops the second from running"

setup second-check-fails
add_second_check
echo 2 > "$fake/second-check-exit"
run
check "$(outcome)" preflight-check-failed "a second check that exits 2 fails the run after the first passed"
check "$(called preflight-check)" called "the first check ran before the second failed"
check "$(called mount-volume uvx)" none "a failing second check mounts nothing and exports nothing"
check "$(grep -c 'second-check.sh second-arg other-arg exited 2' "$fake/app/osxphotos-nas-mirror.log")" 1 \
    "the log names the second check as the one that decided"

setup blank-check
echo 'PREFLIGHT_CHECKS=("   ")' >> "$fake/test.conf"
run
check "$(outcome)" usage-error "a blank PREFLIGHT_CHECKS entry ends with outcome=usage-error"
check "$(called mount-volume uvx)" none "a blank PREFLIGHT_CHECKS entry mounts nothing and exports nothing"

setup second-check-skips
add_second_check
echo 1 > "$fake/second-check-exit"
run
check "$(outcome)" skipped-preflight-check "a second check that exits 1 skips the run after the first passed"

setup force-skips-all-checks
add_second_check
echo 1 > "$fake/preflight-check-exit"
echo 2 > "$fake/second-check-exit"
run --force
check "$(outcome)" ok "--force skips every preflight check"
check "$(called preflight-check second-check)" none "--force runs none of several checks"

setup skip-preflight-check
echo 1 > "$fake/preflight-check-exit"
run --skip-preflight-check
check "$rc" 0 "--skip-preflight-check run exits 0 when the preflight check would stop it"
check "$(outcome)" ok "--skip-preflight-check run ends with outcome=ok"
check "$(called preflight-check)" none "--skip-preflight-check does not run the preflight check"
check "$(grep -c 'Preflight checks skipped' "$fake/app/osxphotos-nas-mirror.log")" 1 \
    "--skip-preflight-check logs that the preflight check was skipped"

# A relative command (it has a "/") is run from the script's own directory, so
# the case runs a copy of the script with a preflight-checks/ stub beside it.
setup preflight-check-relative
mkdir -p "$fake/copy/preflight-checks"
cp "$root/osxphotos-nas-mirror.sh" "$fake/copy/osxphotos-nas-mirror.sh"
cp "$fake/preflight-check.sh" "$fake/copy/preflight-checks/check.sh"
grep -v '^PREFLIGHT_CHECKS=' "$fake/test.conf" > "$fake/trimmed.conf"
mv "$fake/trimmed.conf" "$fake/test.conf"
echo 'PREFLIGHT_CHECKS=("preflight-checks/check.sh a-relative-argument")' >> "$fake/test.conf"
script=$fake/copy/osxphotos-nas-mirror.sh
cd "$work"
run
cd "$root"
script=$root/osxphotos-nas-mirror.sh
check "$(outcome)" ok "a relative preflight check is found beside the script"
check "$(cat "$fake/preflight-check-args.log")" "a-relative-argument" \
    "a relative preflight check is run with the arguments the conf gives it"

# A bare name (no "/") is looked up on PATH, as bash does.
setup preflight-check-bare-name
cp "$fake/preflight-check.sh" "$fake/bin-check"
mkdir -p "$fake/pathdir"
mv "$fake/bin-check" "$fake/pathdir/bare-check"
grep -v '^PREFLIGHT_CHECKS=' "$fake/test.conf" > "$fake/trimmed.conf"
mv "$fake/trimmed.conf" "$fake/test.conf"
echo 'PREFLIGHT_CHECKS=("bare-check a-bare-argument")' >> "$fake/test.conf"
PATH="$fake/pathdir:$PATH" run
check "$(outcome)" ok "a bare preflight check name is found on PATH"
check "$(cat "$fake/preflight-check-args.log")" "a-bare-argument" \
    "a bare preflight check name is run with the arguments the conf gives it"

setup preflight-check-skips
echo 1 > "$fake/preflight-check-exit"
run
check "$rc" 0 "a preflight check that exits 1 ends the run with exit 0"
check "$(outcome)" skipped-preflight-check "a preflight check that exits 1 ends with outcome=skipped-preflight-check"
check "$(called osascript)" none "a preflight check that exits 1 posts no notification"
check "$(called mount-volume uvx)" none \
    "a preflight check that exits 1 neither mounts the share nor runs osxphotos"
check "$(grep -c 'Preflight check .* exited 1' "$fake/app/osxphotos-nas-mirror.log")" 1 \
    "a preflight check that exits 1 has its code logged"

setup preflight-check-fails
echo 2 > "$fake/preflight-check-exit"
run
check "$rc" 70 "a preflight check that exits 2 ends the run with exit 70"
check "$(outcome)" preflight-check-failed "a preflight check that exits 2 ends with outcome=preflight-check-failed"
check "$(notified preflight-check-failed)" yes "a preflight check that exits 2 posts a notification naming preflight-check-failed"
check "$(called mount-volume uvx)" none \
    "a preflight check that exits 2 neither mounts the share nor runs osxphotos"
check "$(grep -c 'Preflight check .* exited 2' "$fake/app/osxphotos-nas-mirror.log")" 1 \
    "a preflight check that exits 2 has its code logged"

setup preflight-check-not-executable
chmod -x "$fake/preflight-check.sh"
run
check "$(outcome)" preflight-check-failed "a preflight check that cannot be run ends with outcome=preflight-check-failed"
check "$(grep -c 'Preflight check .* exited 126' "$fake/app/osxphotos-nas-mirror.log")" 1 \
    "a preflight check that cannot be run has bash's 126 logged"
check "$(called mount-volume uvx)" none "a preflight check that cannot be run does not mount or export"

setup preflight-check-missing
rm "$fake/preflight-check.sh"
run
check "$(outcome)" preflight-check-failed "a preflight check that is missing ends with outcome=preflight-check-failed"
check "$(grep -c 'Preflight check .* exited 127' "$fake/app/osxphotos-nas-mirror.log")" 1 \
    "a preflight check that is missing has bash's 127 logged"

# The example dock check, run as a process with the stub ifconfig.
dock_check=$root/preflight-checks/dock-connected.sh
setup dock-check-docked
rc=0
env PATH="$work/bin:$PATH" FAKE_DIR="$fake" "$dock_check" "$dock_mac" > /dev/null 2>&1 || rc=$?
check "$rc" 0 "the dock check exits 0 when the dock's MAC address is present"

setup dock-check-undocked
: > "$fake/undocked"
rc=0
env PATH="$work/bin:$PATH" FAKE_DIR="$fake" "$dock_check" "$dock_mac" > /dev/null 2>&1 || rc=$?
check "$rc" 1 "the dock check exits 1 when the dock's MAC address is absent"

setup dock-check-uppercase
rc=0
env PATH="$work/bin:$PATH" FAKE_DIR="$fake" "$dock_check" "AA:BB:CC:DD:EE:FF" > /dev/null 2>&1 || rc=$?
check "$rc" 0 "the dock check ignores the case of the MAC address"

setup dock-check-no-argument
rc=0
env PATH="$work/bin:$PATH" FAKE_DIR="$fake" "$dock_check" > "$fake/stdout" 2> "$fake/stderr" || rc=$?
check "$rc" 2 "the dock check with no MAC address exits 2"
check "$(grep -c -i 'usage' "$fake/stderr")" 1 "the dock check with no MAC address prints a usage message"

setup dock-check-as-preflight-check
: > "$fake/undocked"
echo 'PREFLIGHT_CHECKS=("'"$dock_check $dock_mac"'")' >> "$fake/test.conf"
run
check "$(outcome)" skipped-preflight-check "the dock check as the preflight check skips a run away from the dock"
check "$rc" 0 "the dock check as the preflight check skips with exit 0"

setup dock-check-as-preflight-check-no-mac
echo 'PREFLIGHT_CHECKS=("'"$dock_check"'")' >> "$fake/test.conf"
run
check "$(outcome)" preflight-check-failed "the dock check with no MAC address as the preflight check ends preflight-check-failed"

setup mount-failed
: > "$fake/mount-fails"
run
check "$rc" 69 "share that will not mount exits 69"
check "$(outcome)" mount-failed "share that will not mount ends with outcome=mount-failed"
check "$(called uvx)" none \
    "share that will not mount does not run osxphotos"
check "$(notified mount-failed)" yes "share that will not mount posts a notification naming mount-failed"
check "$(grep -c "See $fake/app/osxphotos-nas-mirror.log\." "$fake/osascript-args.log")" 1 \
    "a run that fails before the export names the run log in its notification"
check "$([ -e "$fake/app/exports" ] && echo present || echo absent)" absent \
    "a run that fails before the export writes no export log"

setup mount-hangs
: > "$fake/mount-hangs"
started=$(date +%s)
run
took=$(($(date +%s) - started))
check "$([ "$took" -lt 10 ] && echo bounded || echo "hung ${took}s")" bounded \
    "a mount that hangs is given up after MOUNT_TIMEOUT"
check "$(outcome)" mount-failed "a mount that hangs ends with outcome=mount-failed"
check "$(called uvx)" none "a mount that hangs does not run osxphotos"

# Mounted from Finder, under another name, with the server's name in
# another case: the run finds it and exports there.
setup already-mounted
mkdir -p "$fake/Volumes/photos-1"
echo "//tim@NAS.test/photos on $fake/Volumes/photos-1 (smbfs, nodev, nosuid, mounted by tim)" > "$fake/mounts"
run
check "$rc" 0 "already-mounted share exits 0"
check "$(outcome)" ok "already-mounted share ends with outcome=ok"
check "$(called mount-volume)" none \
    "already-mounted share is not mounted again"
check "$(tail -n 1 "$fake/uvx-args.log")" "$fake/Volumes/photos-1" \
    "already-mounted share is exported to where it is mounted"

setup export-failed
: > "$fake/export-fails"
run
check "$rc" 70 "failed export exits 70"
check "$(outcome)" export-failed "failed export ends with outcome=export-failed"
check "$(notified export-failed)" yes "failed export posts a notification naming export-failed"
check "$(grep -c 'Terminated' "$fake/stderr")" 0 \
    "posting a notification leaves no job-control noise on stderr"
check "$([ -e "$fake/Volumes/photos/.osxphotos_export.db" ] && echo copied || echo absent)" absent \
    "failed export does not copy the export database to the share"

setup share-drops
: > "$fake/share-drops"
started=$(date +%s)
run
took=$(($(date +%s) - started))
check "$rc" 69 "share lost during the export exits 69"
check "$(outcome)" share-lost "share lost during the export ends with outcome=share-lost"
check "$(notified share-lost)" yes "share lost during the export posts a notification naming share-lost"
check "$([ -e "$fake/export-finished" ] && echo finished || echo stopped)" stopped \
    "share lost during the export stops osxphotos"
check "$([ "$took" -lt 6 ] && echo quick || echo "took ${took}s")" quick \
    "share lost during the export ends the run within a few seconds"
check "$([ -e "$fake/Volumes/photos/.osxphotos_export.db" ] && echo copied || echo absent)" absent \
    "share lost during the export does not copy the export database"
check "$(grep -c 'Terminated' "$fake/stderr")" 0 \
    "stopping osxphotos leaves no job-control noise on stderr"

setup share-drops-at-end
: > "$fake/share-drops-at-end"
run
check "$rc" 69 "share lost as the export finishes exits 69"
check "$(outcome)" share-lost "share lost as the export finishes ends with outcome=share-lost"
check "$([ -e "$fake/Volumes/photos/.osxphotos_export.db" ] && echo copied || echo absent)" absent \
    "share lost as the export finishes does not copy the export database"

# A read-only share blocks cp only for a non-root user.
setup db-copy-failed
: > "$fake/share-readonly"
run
check "$rc" 74 "failed copy of the export database exits 74"
check "$(outcome)" db-copy-failed "failed copy of the export database ends with outcome=db-copy-failed"
check "$(notified db-copy-failed)" yes "failed copy of the export database posts a notification naming db-copy-failed"

setup unknown-argument
run --skip-location-check
check "$rc" 64 "an unknown argument (the old --skip-location-check) exits 64"
check "$(outcome)" usage-error "unknown argument ends with outcome=usage-error"
check "$(notified usage-error)" yes "unknown argument posts a notification naming usage-error"
check "$(called uvx)" none \
    "unknown argument does not run osxphotos"

# With no conf there is no log file, so the outcome goes to stderr.
setup missing-conf
rm "$fake/test.conf"
run
check "$rc" 64 "missing conf exits 64"
check "$(grep -c 'outcome=usage-error' "$fake/stderr")" 1 "missing conf reports outcome=usage-error on stderr"
check "$(notified usage-error)" yes "missing conf posts a notification naming usage-error"
check "$(grep -c "See this run's error output (under launchd, the agent's log)\." "$fake/osascript-args.log")" 1 \
    "with no log file, the notification points at the run's error output"
check "$(called mount-volume uvx)" none \
    "missing conf neither mounts the share nor runs osxphotos"

# An unreadable conf, like a read-only share, needs a non-root user.
setup unreadable-conf
chmod a-r "$fake/test.conf"
run
check "$rc" 64 "unreadable conf exits 64"
check "$(grep -c 'outcome=usage-error' "$fake/stderr")" 1 "unreadable conf reports outcome=usage-error on stderr"
check "$(notified usage-error)" yes "unreadable conf posts a notification naming usage-error"

setup conf-missing-setting
grep -v '^LOG_FILE=' "$fake/test.conf" > "$fake/trimmed.conf"
mv "$fake/trimmed.conf" "$fake/test.conf"
run
check "$rc" 64 "conf without LOG_FILE exits 64"
check "$(grep -c 'outcome=usage-error' "$fake/stderr")" 1 "conf without LOG_FILE reports outcome=usage-error on stderr"
check "$(notified usage-error)" yes "conf without LOG_FILE posts a notification naming usage-error"
check "$(called mount-volume uvx)" none \
    "conf without LOG_FILE neither mounts the share nor runs osxphotos"

setup conf-syntax-error
echo 'if then fi' >> "$fake/test.conf"
run
check "$rc" 64 "conf with a syntax error exits 64"
check "$(notified usage-error)" yes "conf with a syntax error posts a notification naming usage-error"
check "$(called mount-volume uvx)" none \
    "conf with a syntax error neither mounts the share nor runs osxphotos"

setup notify-fails
: > "$fake/export-fails"
: > "$fake/notify-fails"
run
check "$rc" 70 "a notification that cannot be posted does not change the exit code"
check "$(outcome)" export-failed "a notification that cannot be posted does not change the outcome"
check "$(grep -c 'WARNING: Could not post a notification' "$fake/app/osxphotos-nas-mirror.log")" 1 \
    "a notification that cannot be posted is logged as a warning"

setup notify-hangs
: > "$fake/export-fails"
: > "$fake/notify-hangs"
started=$(date +%s)
run
took=$(($(date +%s) - started))
check "$([ "$took" -lt 10 ] && echo bounded || echo "hung ${took}s")" bounded \
    "a notification that hangs is given up after NOTIFY_TIMEOUT"
check "$(outcome)" export-failed "a notification that hangs does not change the outcome"
check "$(grep -c 'WARNING: Could not post a notification' "$fake/app/osxphotos-nas-mirror.log")" 1 \
    "a notification that hangs is logged as a warning"

# --- the run log (LOG_FILE) and the export logs (exports/ in the app directory)

# export_logs: the case's export logs, by name, oldest first.
export_logs() {
    ls "$fake/app/exports" 2> /dev/null || true
}

# named_export_log: the export log this case's run log points at.
named_export_log() {
    sed -n 's/.*Export log: //p' "$fake/app/osxphotos-nas-mirror.log" | tail -n 1
}

# old_run_log N: a run log of N lines, "old line 1" to "old line N".
old_run_log() {
    mkdir -p "$fake/app"
    seq 1 "$1" | sed 's/^/old line /' > "$fake/app/osxphotos-nas-mirror.log"
}

# old_export_logs: nine export logs from earlier runs, a day apart.
old_export_logs() {
    mkdir -p "$fake/app/exports"
    for d in 1 2 3 4 5 6 7 8 9; do
        echo "an earlier export" > "$fake/app/exports/2020-01-0${d}T00-00-00.log"
    done
}

setup logs-ok
run
run_log=$fake/app/osxphotos-nas-mirror.log
export_log=$(named_export_log)
check "$(outcome)" ok "a run that exports ends ok"
check "$(dirname "$export_log")" "$fake/app/exports" \
    "the run log names an export log in exports/ in the app directory"
check "$(basename "$export_log" | grep -c -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}\.log$')" 1 \
    "the export log is named after the run's start time, with no colons"
check "$(export_logs)" "$(basename "$export_log")" "a run that exports writes one export log"
check "$(grep -c 'Exporting IMG_0001.HEIC' "$export_log")" 1 "the export log holds osxphotos' output"
check "$(grep -c -e 'Exporting IMG_' -e 'Exported new file' "$run_log")" 0 \
    "the run log holds none of osxphotos' per-photo lines"
check "$(grep -c 'Processed: 3 photos, exported: 1, updated: 1, skipped: 1, updated EXIF data: 0, missing: 0, error: 0, touched date: 2$' "$run_log")" 1 \
    "the run log has osxphotos' summary line"
check "$(grep -c 'Deleted: 1 file, 0 directories$' "$run_log")" 1 \
    "the run log has osxphotos' cleanup line"

setup logs-no-summary
: > "$fake/no-summary"
run
check "$(outcome)" ok "an export that prints no summary still ends ok"
check "$(grep -c 'osxphotos printed no summary' "$fake/app/osxphotos-nas-mirror.log")" 1 \
    "an export that prints no summary leaves a line in the run log saying so"

setup logs-export-failed
: > "$fake/export-fails"
run
export_log=$(named_export_log)
check "$(outcome)" export-failed "a failed export ends export-failed"
check "$(grep -c "See $export_log\." "$fake/osascript-args.log")" 1 \
    "export-failed names the run's export log in its notification"
check "$(grep -c 'osxphotos: export failed' "$export_log")" 1 \
    "the export log holds osxphotos' error output"
check "$(grep -c 'osxphotos printed no summary' "$fake/app/osxphotos-nas-mirror.log")" 1 \
    "a failed export with no summary says so in the run log"

setup logs-share-lost
: > "$fake/share-drops"
run
export_log=$(named_export_log)
check "$(outcome)" share-lost "a share lost during the export ends share-lost"
check "$(grep -c "See $export_log\." "$fake/osascript-args.log")" 1 \
    "share-lost names the run's export log in its notification"
check "$(grep -c 'osxphotos printed no summary' "$fake/app/osxphotos-nas-mirror.log")" 1 \
    "an export stopped by the watchdog says in the run log that it printed no summary"

setup logs-pruned
old_export_logs
run
check "$(export_logs | wc -l | tr -d ' ')" 8 "with 9 export logs, a run that exports leaves 8"
check "$(export_logs | head -n 7)" "$(for d in 3 4 5 6 7 8 9; do echo "2020-01-0${d}T00-00-00.log"; done)" \
    "a run that exports keeps the 7 newest earlier export logs"
check "$(export_logs | tail -n 1)" "$(basename "$(named_export_log)")" \
    "a run that exports keeps its own export log"

setup logs-skipped-recent
old_export_logs
touch "$fake/app/last-ok"
run
check "$(outcome)" skipped-recent "a run with a fresh stamp ends skipped-recent"
check "$(export_logs | wc -l | tr -d ' ')" 9 "a skipped-recent run neither writes nor deletes export logs"

setup logs-skipped-preflight-check
old_export_logs
echo 1 > "$fake/preflight-check-exit"
run
check "$(export_logs | wc -l | tr -d ' ')" 9 "a skipped-preflight-check run neither writes nor deletes export logs"

setup run-log-trimmed
old_run_log 10050
run
run_log=$fake/app/osxphotos-nas-mirror.log
old=$(grep -c '^old line ' "$run_log" || true)
check "$(wc -l < "$run_log" | tr -d ' ')" 10000 "a run log longer than 10,000 lines is trimmed to 10,000"
check "$(outcome)" ok "the trimmed run log ends with the outcome"
check "$(head -n 1 "$run_log")" "old line $((10051 - old))" \
    "the trimmed run log starts where its last 10,000 lines start"
check "$(grep -n '^old line 10050$' "$run_log" | cut -d: -f1)" "$old" \
    "the trimmed run log keeps the earlier lines in one piece, before this run's"

setup run-log-short
old_run_log 20
run
check "$(head -n 1 "$fake/app/osxphotos-nas-mirror.log")" "old line 1" \
    "a run log under 10,000 lines is not trimmed"
check "$(grep -c '^old line ' "$fake/app/osxphotos-nas-mirror.log")" 20 \
    "a run log under 10,000 lines keeps every earlier line"

# The run holding the lock may be writing to the run log, so a run that finds
# the lock held leaves it alone; the holder trims it when it ends.
setup run-log-locked
old_run_log 10050
hold_lock "$fake/run.lock"
run
kill "$holder" 2> /dev/null || true
wait "$holder" 2> /dev/null || true
check "$(outcome)" skipped-locked "a run that finds the lock held ends skipped-locked"
check "$(head -n 1 "$fake/app/osxphotos-nas-mirror.log")" "old line 1" \
    "a run that finds the lock held does not trim the run log"

# A skipped run trims too. Here the app directory is read-only, so the trim
# can't write its new file.
setup run-log-trim-fails
old_run_log 10050
touch "$fake/app/last-ok"
chmod a-w "$fake/app"
run
chmod u+w "$fake/app"
check "$rc" 0 "a run log that cannot be trimmed does not change the exit code"
check "$(outcome)" skipped-recent "a run log that cannot be trimmed does not change the outcome"
check "$(grep -c 'WARNING: Could not trim the run log' "$fake/app/osxphotos-nas-mirror.log")" 1 \
    "a run log that cannot be trimmed is logged as a warning"
check "$(head -n 1 "$fake/app/osxphotos-nas-mirror.log")" "old line 1" \
    "a run log that cannot be trimmed is left whole"

# --- the run lock: a kernel lock (flock) on LOCK_FILE, held by the run and
# by the export it starts

# Another run holds the lock: hold it here meanwhile.
setup locked
hold_lock "$fake/run.lock"
run
kill "$holder" 2> /dev/null || true
wait "$holder" 2> /dev/null || true
check "$rc" 0 "run that finds another run in progress exits 0"
check "$(outcome)" skipped-locked "run that finds another run in progress ends with outcome=skipped-locked"
check "$(called mount-volume uvx osascript)" none \
    "run that finds another run in progress mounts nothing, exports nothing and posts no notification"

setup lock-released
hold_lock "$fake/run.lock"
kill "$holder"
wait "$holder" 2> /dev/null || true
run
check "$(outcome)" ok "a lock file left by a finished run does not block the next run"

# A run killed outright (SIGKILL, which can't be trapped) leaves its export
# running. The export holds the lock, so the next run must not start a second.
setup killed-mid-export
: > "$fake/export-runs"
start_run
wait_for "$fake/export.pid"
kill -KILL "$run_pid"
wait "$run_pid" 2> /dev/null || true
export_pid=$(cat "$fake/export.pid")
check "$(alive "$export_pid")" alive "the export of a run killed with SIGKILL runs on"
# The killed run mounted the share; record only what the next run does.
rm -f "$fake/mount-volume-args.log" "$fake/osascript-args.log"
run
check "$rc" 0 "a run while a killed run's export runs on exits 0"
check "$(outcome)" skipped-locked "a run while a killed run's export runs on ends with outcome=skipped-locked"
check "$(wc -l < "$fake/uvx-calls.log" | tr -d ' ')" 1 \
    "a run while a killed run's export runs on starts no second export"
check "$(called mount-volume osascript)" none \
    "a run while a killed run's export runs on mounts nothing and posts no notification"
# Once that export ends, the lock is free again.
: > "$fake/export-stop"
wait_gone "$export_pid"
rm "$fake/export-runs"
run
check "$(outcome)" ok "once a killed run's export has ended, the next run gets the lock and ends ok"
check "$(wc -l < "$fake/uvx-calls.log" | tr -d ' ')" 2 \
    "once a killed run's export has ended, the next run exports"

# A run stopped politely (SIGTERM) stops its export and ends with an outcome.
setup terminated-mid-export
: > "$fake/export-runs"
start_run
wait_for "$fake/export.pid"
export_pid=$(cat "$fake/export.pid")
kill -TERM "$run_pid"
rc=0
wait "$run_pid" 2> /dev/null || rc=$?
log=$(cat "$fake/app/osxphotos-nas-mirror.log" 2> /dev/null || true)
check "$(alive "$export_pid")" gone "SIGTERM to a run stops its export"
check "$rc" 75 "a run stopped with SIGTERM exits 75"
check "$(outcome)" interrupted "a run stopped with SIGTERM ends with outcome=interrupted"
check "$(notified interrupted)" yes "a run stopped with SIGTERM posts a notification naming interrupted"
check "$(grep -c "See $(named_export_log)\." "$fake/osascript-args.log")" 1 \
    "a run stopped mid-export names its export log in the notification"
check "$(grep -c 'osxphotos printed no summary' "$fake/app/osxphotos-nas-mirror.log")" 1 \
    "a run stopped mid-export says in the run log that osxphotos printed no summary"
check "$([ -e "$fake/Volumes/photos/.osxphotos_export.db" ] && echo copied || echo absent)" absent \
    "a run stopped with SIGTERM does not copy the export database"
check "$([ -e "$fake/app/last-ok" ] && echo yes || echo no)" no "a run stopped with SIGTERM writes no stamp"
check "$(grep -c 'Terminated' "$fake/stderr")" 0 \
    "stopping a run with SIGTERM leaves no job-control noise on stderr"
: > "$fake/export-stop"

setup hung-up-mid-export
: > "$fake/export-runs"
start_run
wait_for "$fake/export.pid"
export_pid=$(cat "$fake/export.pid")
kill -HUP "$run_pid"
wait "$run_pid" 2> /dev/null || true
log=$(cat "$fake/app/osxphotos-nas-mirror.log" 2> /dev/null || true)
check "$(alive "$export_pid")" gone "SIGHUP to a run stops its export"
check "$(outcome)" interrupted "a run stopped with SIGHUP ends with outcome=interrupted"
: > "$fake/export-stop"

# With no LOCK_FILE, the lock file is run.lock in the app directory.
setup default-lock-file
grep -v '^LOCK_FILE=' "$fake/test.conf" > "$fake/trimmed.conf"
mv "$fake/trimmed.conf" "$fake/test.conf"
run
check "$(outcome)" ok "a run with no LOCK_FILE ends ok"
check "$([ -f "$fake/app/run.lock" ] && echo present || echo absent)" present \
    "with no LOCK_FILE, the lock file is run.lock in the app directory"

setup lock-file-relative
echo 'LOCK_FILE="run.lock"' >> "$fake/test.conf"
run
check "$rc" 64 "a relative LOCK_FILE exits 64"
check "$(outcome)" usage-error "a relative LOCK_FILE ends with outcome=usage-error"
check "$(grep -c 'LOCK_FILE .* is not an absolute path' "$fake/app/osxphotos-nas-mirror.log")" 1 \
    "a relative LOCK_FILE is logged"
check "$(called mount-volume uvx)" none "a relative LOCK_FILE mounts nothing and exports nothing"

# A lock file that can't be opened: here, a directory.
setup lock-file-is-a-directory
mkdir -p "$fake/lock-dir"
echo 'LOCK_FILE="'"$fake"'/lock-dir"' >> "$fake/test.conf"
run
check "$rc" 64 "a lock file that cannot be opened exits 64"
check "$(outcome)" usage-error "a lock file that cannot be opened ends with outcome=usage-error"
check "$(grep -c 'Cannot open the lock file' "$fake/app/osxphotos-nas-mirror.log")" 1 \
    "a lock file that cannot be opened is logged"
check "$(called mount-volume uvx)" none "a lock file that cannot be opened mounts nothing and exports nothing"

setup lock-dir-missing
echo 'LOCK_FILE="'"$fake"'/no-such-dir/run.lock"' >> "$fake/test.conf"
run
check "$(outcome)" usage-error "a lock file in a directory that does not exist ends with outcome=usage-error"

setup no-keychain
: > "$fake/no-keychain"
run
check "$rc" 78 "share with no keychain password exits 78"
check "$(outcome)" no-credentials "share with no keychain password ends with outcome=no-credentials"
check "$(called mount-volume uvx)" none \
    "share with no keychain password is neither mounted nor exported to"
check "$(notified no-credentials)" yes "share with no keychain password posts a notification naming no-credentials"
check "$(grep -c -- '-a tim -s nas.test -r smb ' "$fake/security-args.log")" 1 \
    "the keychain is searched for NAS_USER at NAS_HOSTNAME over SMB"
check "$(grep -c 'Finder' "$fake/app/osxphotos-nas-mirror.log")" 1 \
    "the no-credentials log line points at Finder"
check "$(grep -c -- '--save-password' "$fake/app/osxphotos-nas-mirror.log")" 0 \
    "the no-credentials log line does not mention --save-password"

setup no-keychain-already-mounted
: > "$fake/no-keychain"
mkdir -p "$fake/Volumes/photos"
echo "//tim@nas.test/photos on $fake/Volumes/photos (smbfs, nodev, nosuid)" > "$fake/mounts"
run
check "$(outcome)" ok "an already-mounted share needs no keychain password"

# --- weekly gate: the stamp $APP_DIR/last-ok, written by a run that ends ok

# days_ago N: a touch -t timestamp N days back.
days_ago() {
    date -v-"$1"d +%Y%m%d%H%M 2> /dev/null || date -d "$1 days ago" +%Y%m%d%H%M
}

# stamp_state: "yes" if the case has a stamp, else "no".
stamp_state() {
    if [ -e "$fake/app/last-ok" ]; then echo yes; else echo no; fi
}

setup no-stamp
run
check "$(outcome)" ok "a run with no stamp goes ahead"
check "$(stamp_state)" yes "a run that ends ok writes the stamp"

setup fresh-stamp
mkdir -p "$fake/app"
touch "$fake/app/last-ok"
run
check "$rc" 0 "a run with a fresh stamp exits 0"
check "$(outcome)" skipped-recent "a run with a fresh stamp ends with outcome=skipped-recent"
check "$(called mount-volume uvx osascript preflight-check)" none \
    "a run with a fresh stamp runs no preflight check, mounts nothing, exports nothing and posts no notification"
check "$(grep -c 'Last good run' "$fake/app/osxphotos-nas-mirror.log")" 1 \
    "a skipped-recent run logs when the last good run was"

setup stale-stamp
mkdir -p "$fake/app"
touch -t "$(days_ago 8)" "$fake/app/last-ok"
run
check "$(outcome)" ok "a run with an eight-day-old stamp goes ahead"
check "$([ -n "$(find "$fake/app/last-ok" -mtime -1)" ] && echo fresh || echo stale)" fresh \
    "a run that ends ok refreshes the stamp"

setup interval-zero
echo 'MIRROR_INTERVAL_DAYS=0' >> "$fake/test.conf"
mkdir -p "$fake/app"
touch "$fake/app/last-ok"
run
check "$(outcome)" ok "MIRROR_INTERVAL_DAYS=0 turns the gate off"

setup interval-three
echo 'MIRROR_INTERVAL_DAYS=3' >> "$fake/test.conf"
mkdir -p "$fake/app"
touch -t "$(days_ago 5)" "$fake/app/last-ok"
run
check "$(outcome)" ok "a stamp older than MIRROR_INTERVAL_DAYS lets the run go ahead"

setup failed-no-stamp
: > "$fake/export-fails"
run
check "$(outcome)" export-failed "a failing run ends export-failed"
check "$(stamp_state)" no "a failed run writes no stamp"

setup failed-keeps-stamp
: > "$fake/export-fails"
mkdir -p "$fake/app"
touch -t "$(days_ago 8)" "$fake/app/last-ok"
run
check "$(outcome)" export-failed "a failing run with an old stamp ends export-failed"
check "$([ -n "$(find "$fake/app/last-ok" -mtime +7)" ] && echo stale || echo fresh)" stale \
    "a failed run leaves an old stamp alone"

setup skipped-no-stamp
echo 1 > "$fake/preflight-check-exit"
run
check "$(outcome)" skipped-preflight-check "a run the preflight check skips ends skipped-preflight-check"
check "$(stamp_state)" no "a skipped run writes no stamp"

setup force
mkdir -p "$fake/app"
touch "$fake/app/last-ok"
echo 1 > "$fake/preflight-check-exit"
run --force
check "$(outcome)" ok "--force runs despite a fresh stamp and a preflight check that would skip"
check "$(called preflight-check)" none "--force does not run the preflight check"

setup skip-preflight-keeps-gate
mkdir -p "$fake/app"
touch "$fake/app/last-ok"
run --skip-preflight-check
check "$(outcome)" skipped-recent "--skip-preflight-check still honours the recency gate"

setup bad-interval
echo 'MIRROR_INTERVAL_DAYS=weekly' >> "$fake/test.conf"
run
check "$rc" 64 "a MIRROR_INTERVAL_DAYS that is not a number exits 64"
check "$(outcome)" usage-error "a MIRROR_INTERVAL_DAYS that is not a number ends with outcome=usage-error"
check "$(called mount-volume uvx)" none "a bad MIRROR_INTERVAL_DAYS mounts nothing and exports nothing"

setup two-flags
run --force --skip-preflight-check
check "$(outcome)" usage-error "two flags end with outcome=usage-error"

if [ "$failures" -ne 0 ]; then
    echo "$failures of $count checks failed"
    exit 1
fi
echo "all $count checks passed"
