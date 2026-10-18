#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later

# log MESSAGE: a timestamped line to stdout and the log file. Before the conf
# is loaded there is no log file, so the line goes to stderr instead.
log() {
    local line
    line="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    if [ -n "${LOG_FILE:-}" ]; then
        echo "$line" | tee -a "$LOG_FILE"
    else
        echo "$line" >&2
    fi
}

# bounded SECONDS COMMAND...: run COMMAND, giving it SECONDS (macOS has no
# timeout command). Fails if COMMAND fails or is killed for taking too long.
bounded() {
    local seconds=$1 pid watcher
    shift
    "$@" &
    pid=$!
    # The watcher doesn't get the run lock's descriptor: killing it below
    # leaves its sleep behind, which would hold the lock until it ends.
    (sleep "$seconds" && kill "$pid") > /dev/null 2>&1 9>&- &
    watcher=$!
    # Killing the watcher below would otherwise make bash print
    # "Terminated" on stderr, which under launchd is the log.
    disown "$watcher"
    if wait "$pid"; then
        kill "$watcher" 2> /dev/null
        return 0
    fi
    return 1
}

# notify MESSAGE: post a macOS notification. The text goes in as osascript
# arguments, not into the script source, so it needs no escaping. osascript
# gets NOTIFY_TIMEOUT seconds (default 10), so a hung one can't stop the
# outcome line being written. A notification that fails or times out is
# logged and never changes the run's outcome.
notify() {
    if ! bounded "${NOTIFY_TIMEOUT:-10}" osascript -e 'on run argv' \
        -e 'display notification (item 1 of argv) with title "osxphotos NAS mirror"' \
        -e 'end run' "$1" > /dev/null; then
        log "WARNING: Could not post a notification."
    fi
}

# share_mount_point: print where the share is mounted, from mount's
# //user@host/share line of type smbfs (compared without regard to case, as
# Finder may write the server's name differently). Prints nothing if the
# share is not mounted.
share_mount_point() {
    mount | awk -v want="//${NAS_USER}@${NAS_HOSTNAME}/${NAS_SHARE}" '
        tolower($1) == tolower(want) && $2 == "on" && index($0, " (smbfs") {
            point = $0
            sub(/^[^ ]+ on /, "", point)
            sub(/ \(smbfs.*$/, "", point)
            print point
            exit
        }'
}

# finish OUTCOME: end the run. Every run ends here, with one outcome=<name>
# line as the last line of its log and the outcome's exit code (sysexits.h).
finishing=
finish() {
    local code
    finishing=$1
    case "$1" in
        ok | skipped-preflight-check | skipped-locked | skipped-recent) code=0 ;;
        usage-error) code=64 ;;
        mount-failed | share-lost) code=69 ;;
        export-failed | preflight-check-failed) code=70 ;;
        db-copy-failed) code=74 ;;
        interrupted) code=75 ;;
        no-credentials) code=78 ;;
        *)
            # A misspelt outcome is a bug in this script: EX_SOFTWARE.
            log "ERROR: finish called with unknown outcome '$1'."
            code=70
            ;;
    esac
    if [ "$code" -ne 0 ]; then
        if [ -n "${LOG_FILE:-}" ]; then
            notify "Mirror run failed: $1. See $LOG_FILE."
        else
            notify "Mirror run failed: $1. See this run's error output (under launchd, the agent's log)."
        fi
    fi
    log "outcome=$1"
    exit "$code"
}

# This script's own directory, as an absolute path, found once. $0 may be
# bare or relative (`bash osxphotos-nas-mirror.sh`). pwd -P and a cd in a
# subshell work in macOS's bash 3.2, which has no realpath.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)

# Source the configuration file. OSXPHOTOS_NAS_MIRROR_CONF overrides it (the
# fixture tests use this); unset, it is the conf in the app directory. The
# repo ships only an example, osxphotos-nas-mirror.conf.example.
CONF="${OSXPHOTOS_NAS_MIRROR_CONF:-$HOME/Library/Application Support/osxphotos-nas-mirror/osxphotos-nas-mirror.conf}"
if [ ! -r "$CONF" ]; then
    log "ERROR: Cannot read configuration file $CONF."
    finish usage-error
fi
# shellcheck source=osxphotos-nas-mirror.conf.example
if ! source "$CONF"; then
    log "ERROR: Configuration file $CONF did not load."
    finish usage-error
fi
for setting in NAS_USER NAS_HOSTNAME NAS_SHARE \
    APP_DIR LOG_FILE OSXPHOTOS_EXPORT_DB; do
    if [ -z "${!setting:-}" ]; then
        # The log file may be the missing setting, so report on stderr.
        LOG_FILE=
        log "ERROR: Configuration file $CONF does not set $setting."
        finish usage-error
    fi
done

# Ensure the application support directory exists
mkdir -p "$APP_DIR"

# MIRROR_INTERVAL_DAYS in the conf is the shortest gap between good runs
# (optional, default 7; 0 turns the gate off).
MIRROR_INTERVAL_DAYS="${MIRROR_INTERVAL_DAYS:-7}"
case "$MIRROR_INTERVAL_DAYS" in
    *[!0-9]*)
        log "ERROR: MIRROR_INTERVAL_DAYS in $CONF is '$MIRROR_INTERVAL_DAYS', not a whole number of days."
        finish usage-error
        ;;
esac

# Process command-line arguments
SKIP_PREFLIGHT_CHECK=false
FORCE=false
case "$#:${1:-}" in
    0:) ;;
    1:--skip-preflight-check)
        SKIP_PREFLIGHT_CHECK=true
        ;;
    1:--force)
        FORCE=true
        SKIP_PREFLIGHT_CHECK=true
        ;;
    *)
        log "ERROR: Unknown arguments: $*. Usage: $(basename "$0") [--skip-preflight-check | --force]"
        finish usage-error
        ;;
esac

# One run at a time, and one export. The run takes a kernel lock (flock) on
# LOCK_FILE through descriptor 9, which the export (uv and osxphotos)
# inherits, so the lock is held while the script or the export still has it
# open: a run killed outright leaves the lock with its export, and later runs
# end skipped-locked until that export ends. However its holders exit, the
# lock goes with the last of them, so a leftover file never blocks a run.
# macOS has no flock command, so perl takes the lock on the inherited
# descriptor. (lockf held the lock in a process of its own, which the export
# could outlive; see docs/adr/0006.)
#
# LOCK_FILE in the conf overrides where it is (an absolute path); unset, it
# is run.lock in APP_DIR.
LOCK_FILE="${LOCK_FILE:-$APP_DIR/run.lock}"
case "$LOCK_FILE" in
    /*) ;;
    *)
        log "ERROR: LOCK_FILE in $CONF is '$LOCK_FILE', which is not an absolute path."
        finish usage-error
        ;;
esac
if ! { exec 9>> "$LOCK_FILE"; } 2> /dev/null; then
    log "ERROR: Cannot open the lock file $LOCK_FILE."
    finish usage-error
fi
lock_rc=0
perl -MFcntl=:flock -e 'open(my $fh, ">&=", 9) or exit 2;
    flock($fh, LOCK_EX | LOCK_NB) and exit 0; exit($!{EWOULDBLOCK} ? 1 : 2)' || lock_rc=$?
case "$lock_rc" in
    0) ;;
    1)
        log "Another run, or its export, holds the lock $LOCK_FILE. Exiting."
        finish skipped-locked
        ;;
    *)
        log "ERROR: Cannot lock $LOCK_FILE (perl exited $lock_rc)."
        finish usage-error
        ;;
esac

# stop_export: stop osxphotos, if it was started, and wait for it. uv runs
# osxphotos as its child: stop that, then uv. Reaping a killed job makes bash
# print "Terminated" on stderr, which under launchd is the log, hence the
# 2> /dev/null on wait. osxphotos is uv's child, not ours, so it is waited for
# by polling, for up to 5 seconds; one that outlives that keeps the lock.
# (launchd gives a job 20 seconds to exit after SIGTERM, and finish may
# still need NOTIFY_TIMEOUT seconds after this.)
stop_export() {
    local children child i
    [ -n "${export_pid:-}" ] || return 0
    children=$(pgrep -P "$export_pid")
    pkill -TERM -P "$export_pid" 2> /dev/null
    kill "$export_pid" 2> /dev/null
    wait "$export_pid" 2> /dev/null
    for child in $children; do
        i=0
        while kill -0 "$child" 2> /dev/null && [ "$i" -lt 25 ]; do
            sleep 0.2 9>&-
            i=$((i + 1))
        done
    done
}

# A run stopped politely (SIGTERM, as launchd sends; SIGINT; SIGHUP) stops
# its export and ends interrupted. The export wouldn't stop by itself: it is
# a separate process, and bash starts a background command with SIGINT
# ignored. A signal while the run is already ending is ignored, and the run
# ends with the outcome it was ending with. SIGKILL can't be trapped; the lock
# covers that.
# shellcheck disable=SC2329 # run by the traps below
on_signal() {
    [ -z "$finishing" ] || return 0
    log "Stopped by $1."
    stop_export
    finish interrupted
}
trap 'on_signal SIGTERM' TERM
trap 'on_signal SIGINT' INT
trap 'on_signal SIGHUP' HUP

# RECENCY GATE (skipped by --force). The launchd agent runs hourly, so a Mac
# that is home at any hour is caught, and the mirror runs about weekly: a run
# that ends ok touches $APP_DIR/last-ok, and until that is MIRROR_INTERVAL_DAYS
# old the run ends skipped-recent. It comes before the preflight checks, so a
# costly check runs at most once a gap, not every hour. No stamp: the run
# goes ahead. Only ok writes the stamp.
STAMP="$APP_DIR/last-ok"
if [ "$FORCE" != true ] && [ "$MIRROR_INTERVAL_DAYS" -gt 0 ] && [ -e "$STAMP" ] &&
    [ -n "$(find "$STAMP" -mtime -"$MIRROR_INTERVAL_DAYS")" ]; then
    log "Last good run was $(date -r "$(stat -f %m "$STAMP")" '+%Y-%m-%d %H:%M:%S'), under $MIRROR_INTERVAL_DAYS days ago. Skipping this run."
    finish skipped-recent
fi

# 1. PREFLIGHT CHECKS (skipped if --skip-preflight-check or --force is provided)
# PREFLIGHT_CHECKS in the conf is a bash array of strings, one per check. Each
# string is split on whitespace into a command and its arguments (so an
# argument can't contain a space) and run before anything is mounted, in
# order. The first check that doesn't exit 0 decides, and later ones don't
# run. Exit 1: the run ends skipped-preflight-check. Any other code,
# including bash's 126 and 127 for a command that can't be run, ends it
# preflight-check-failed. All exit 0, or none set: the run goes ahead.
# A command with a "/" that doesn't start with one is relative to the script's
# directory; a bare name is looked up on PATH, an absolute path is used as is.
if [ "$SKIP_PREFLIGHT_CHECK" = true ]; then
    log "Preflight checks skipped."
elif [ "${#PREFLIGHT_CHECKS[@]}" -gt 0 ]; then
    check_total=${#PREFLIGHT_CHECKS[@]}
    check_number=0
    for check_line in "${PREFLIGHT_CHECKS[@]}"; do
        check_number=$((check_number + 1))
        read -r -a check_cmd <<< "$check_line"
        if [ "${#check_cmd[@]}" -eq 0 ]; then
            log "ERROR: PREFLIGHT_CHECKS entry $check_number in $CONF is empty."
            finish usage-error
        fi
        case "${check_cmd[0]}" in
            /*) ;;
            */*) check_cmd[0]="$SCRIPT_DIR/${check_cmd[0]}" ;;
        esac
        log "Running preflight check $check_number of $check_total: ${check_cmd[*]}"
        preflight_check_rc=0
        "${check_cmd[@]}" >> "$LOG_FILE" 2>&1 || preflight_check_rc=$?
        case "$preflight_check_rc" in
            0) log "Preflight check $check_number of $check_total passed." ;;
            1)
                log "Preflight check ${check_cmd[*]} exited 1. Skipping this run."
                finish skipped-preflight-check
                ;;
            *)
                log "ERROR: Preflight check ${check_cmd[*]} exited $preflight_check_rc."
                finish preflight-check-failed
                ;;
        esac
    done
fi


# 2. MOUNT CHECK
# The share is mounted as Finder mounts it, under /Volumes, and a share
# already mounted from Finder is used where it is. Under /Volumes a share
# that drops leaves no folder to write into: macOS removes the mount point,
# and only root can make one there.
EXPORT_DIR=$(share_mount_point)
if [ -z "$EXPORT_DIR" ]; then
    # mount volume reads the password from the login keychain, as Finder
    # does. Check it is there first, so a missing one ends the run instead
    # of raising a password dialog nobody may be there to answer.
    if ! security find-internet-password -a "$NAS_USER" -s "$NAS_HOSTNAME" -r "smb " > /dev/null 2>&1; then
        log "ERROR: No SMB password for ${NAS_USER}@${NAS_HOSTNAME} in the keychain. Connect to the share once in Finder and tick \"Remember this password in my keychain\"."
        finish no-credentials
    fi
    log "Mounting NAS..."
    bounded "${MOUNT_TIMEOUT:-60}" osascript -e 'on run argv' -e 'mount volume (item 1 of argv)' \
        -e 'end run' "smb://${NAS_USER}@${NAS_HOSTNAME}/${NAS_SHARE}" >> "$LOG_FILE" 2>&1
    EXPORT_DIR=$(share_mount_point)
    if [ -z "$EXPORT_DIR" ]; then
        log "CRITICAL ERROR: Could not mount NAS."
        finish mount-failed
    fi
fi
log "Share mounted at $EXPORT_DIR."

# 3. RUN OSXPHOTOS EXPORT
log "Starting photo library export..."

# osxphotos runs through uv, in its own Python 3.13 environment, pinned to a
# known version: Homebrew's formula broke when Homebrew's cffi dropped
# Python 3.13, and a mirror shouldn't upgrade its exporter between runs.
# OSXPHOTOS_SOURCE in the conf is what uvx installs it from, a PyPI pin
# (osxphotos==0.77.2) or a git+https://…@<tag>. Unset, it is the default
# here: a tag on our fork, which fixes two bugs that make 0.77.2 download
# evicted RAW+JPEG pairs and edited Live Photos again on every run (upstream PRs
# RhetTbull/osxphotos#2265 and #2266); it goes back to a PyPI pin once
# upstream releases the fixes.
# OSXPHOTOS_CONFIG in the conf is the osxphotos TOML; unset, the repo's.
#
# It runs in the background, watched: osxphotos logs a file it can't write
# and carries on, and exits 0, so a share that drops mid-run would otherwise
# go unnoticed. Every SHARE_CHECK_INTERVAL seconds the share must still be
# mounted where the export started, or osxphotos is stopped and the run ends
# share-lost. The export is polled every second, so one that finishes adds at
# most a second to the run. The poll's sleep doesn't get the lock's
# descriptor, so a killed run's last sleep doesn't hold the lock.
share_lost() {
    log "ERROR: The share is no longer mounted at $EXPORT_DIR. $1"
    finish share-lost
}
default_osxphotos_source=git+https://github.com/TimJDFletcher/osxphotos@v0.77.2-tim.3
uvx --python 3.13 \
    --from "${OSXPHOTOS_SOURCE:-$default_osxphotos_source}" \
    osxphotos export \
    --newest-first \
    --load-config "${OSXPHOTOS_CONFIG:-$SCRIPT_DIR/osxphotos.toml}" \
    --exportdb "$OSXPHOTOS_EXPORT_DB" "$EXPORT_DIR" >> "$LOG_FILE" 2>&1 &
export_pid=$!
since_check=0
while kill -0 "$export_pid" 2> /dev/null; do
    sleep 1 9>&-
    since_check=$((since_check + 1))
    if [ "$since_check" -ge "${SHARE_CHECK_INTERVAL:-5}" ]; then
        since_check=0
        if [ "$(share_mount_point)" != "$EXPORT_DIR" ]; then
            # A signal that arrives during this stop_export ends the run
            # interrupted, not share-lost: the trap ends the run before
            # share_lost is reached.
            stop_export
            share_lost "Stopped osxphotos."
        fi
    fi
done
export_rc=0
wait "$export_pid" 2> /dev/null || export_rc=$?
if [ "$export_rc" -ne 0 ]; then
    log "ERROR: The export failed. Check logs for details."
    finish export-failed
fi
log "Export complete."
# A share that went as the export finished must not take the database copy.
if [ "$(share_mount_point)" != "$EXPORT_DIR" ]; then
    share_lost "Not copying the osxphotos database."
fi
log "Copying the osxphotos database to the share..."
if ! cp "$OSXPHOTOS_EXPORT_DB" "$EXPORT_DIR/.osxphotos_export.db"; then
    log "ERROR: Could not copy the osxphotos database to NAS."
    finish db-copy-failed
fi

if ! touch "$STAMP"; then
    log "WARNING: Could not write $STAMP; the next run will not be held back."
fi
log "Mirror run finished."
finish ok
