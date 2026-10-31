#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later

# log MESSAGE: a timestamped line to stdout and the run log. Before the conf
# is loaded there is no run log, so the line goes to stderr instead.
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
    # "Terminated" on stderr, which under launchd is the run log.
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

# The run log (LOG_FILE) keeps its last RUN_LOG_LINES lines, and exports/ in
# the app directory keeps the export logs of the last EXPORT_LOGS_KEPT runs
# that exported. Neither is a conf setting.
RUN_LOG_LINES=10000
EXPORT_LOGS_KEPT=8

# trim_run_log: cut the run log to its last RUN_LOG_LINES - 1 lines, so that
# with the outcome line, written next, it holds RUN_LOG_LINES. The trimmed
# copy replaces the run log in one rename, so a trim that fails leaves it whole,
# and is a warning. Under launchd the script's stderr is still the old file
# after the rename, but nothing is written to it after the outcome.
trim_run_log() {
    local lines
    [ -f "$LOG_FILE" ] || return 0
    lines=$(($(wc -l < "$LOG_FILE")))
    [ "$lines" -ge "$RUN_LOG_LINES" ] || return 0
    if ! { tail -n $((RUN_LOG_LINES - 1)) "$LOG_FILE" > "$LOG_FILE.trim" &&
        mv "$LOG_FILE.trim" "$LOG_FILE"; } 2> /dev/null; then
        rm -f "$LOG_FILE.trim" 2> /dev/null
        log "WARNING: Could not trim the run log $LOG_FILE."
    fi
}

# The fixed set of outcomes, each as name:exit code (sysexits.h). finish
# takes the codes from here, and the metrics textfile has a series for each.
OUTCOMES="ok:0 skipped-preflight-check:0 skipped-locked:0 skipped-recent:0
    usage-error:64 mount-failed:69 share-lost:69 export-failed:70
    preflight-check-failed:70 db-copy-failed:74 interrupted:75 no-credentials:78"

# The metrics textfile (METRICS_TEXTFILE in the conf), for node_exporter's
# textfile collector. Every metric is a gauge named with this prefix.
METRICS_PREFIX=osxphotos_nas_mirror_
# Seconds sqlite3 gets for a query on the export database.
EXPORT_DB_QUERY_SECONDS=60

# export_db_read VAR SQL: set VAR to what SQL selects from the export
# database, columns separated by spaces. On failure VAR is left alone and
# export_db_error says why: the first line of sqlite3's error, or that it ran
# out of EXPORT_DB_QUERY_SECONDS. sqlite3 skips ~/.sqliterc.
#
# The database is opened as a URI with immutable=1, which is read-only and
# also tells SQLite the file can't change, so it takes no locks and doesn't
# look for the WAL files. That is needed: osxphotos keeps the database in WAL
# mode and its SQLite removes the -wal and -shm files when it closes it, and
# macOS's sqlite3 can't open a WAL database read-only (-readonly or mode=ro)
# without them ("unable to open database file"). immutable is sound here
# because both reads happen under the run lock while osxphotos isn't
# running: just before the export starts and after it has exited. The
# caveat: a -wal file left by an osxphotos that was killed is ignored, so
# history_mark can be too low after such a run, and that run's history rows
# then count as this export's; GROUP BY folds most of them into this
# export's own rows for the same files. After osxphotos has closed the
# database cleanly its WAL is in the main file, and the read is exact.
export_db_read() {
    local uri out
    uri=$OSXPHOTOS_EXPORT_DB
    uri=${uri//%/%25}
    uri=${uri// /%20}
    uri=${uri//\?/%3f}
    uri=${uri//#/%23}
    if out=$(bounded "$EXPORT_DB_QUERY_SECONDS" sqlite3 -init /dev/null -batch -bail \
        -noheader -separator ' ' "file:$uri?immutable=1" "$2" 2>&1); then
        printf -v "$1" '%s' "$out"
        return 0
    fi
    export_db_error=$(printf '%s\n' "$out" | head -n 1)
    [ -n "$export_db_error" ] || export_db_error="sqlite3 gave no answer in $EXPORT_DB_QUERY_SECONDS seconds"
    return 1
}

# mirror_from_export_db: after an ok run, set mirror_files, mirror_bytes and
# export_bytes from the export database. Fails, setting none, if it can't,
# with export_db_error saying why.
#
# What osxphotos (export_db.py and photoexporter.py at the pinned tag) keeps
# there, and why the obvious queries are wrong:
# - export_data has a row per file ever exported, with dest_size, its size
#   when osxphotos last wrote it. --cleanup never deletes a row, so rows for
#   files cleaned up, or for photos deleted from the library, stay for good:
#   count(*) and sum(dest_size) over-count.
# - Its timestamp is bumped whenever osxphotos rewrites the row, which it
#   does for most files it checks, but not for one the fork skips without a
#   download because its original isn't on the Mac (the evicted RAW+JPEG
#   pairs and Live Photos the fork exists for), nor for a skipped AAE. So
#   "timestamp since the export started" under-counts.
# - history gets one row for every file the export deals with: action
#   "new", "update: <reason>", "skip", "missing" or "export", each with an
#   "AAE: " form, and no row for a file cleanup deletes. Its id only grows
#   (osxphotos never deletes from it), so the rows after history_mark, its
#   largest id before the export started, are this export's.
# So the mirror is the files with a history row from this export that isn't
# "missing": what the export wrote or found up to date, which is what cleanup
# keeps on the share. Their export_data dest_size summed is mirror_bytes, and
# summed over the new and updated ones only, export_bytes, the bytes written.
# That under-counts what cleanup keeps by the files with no history row from
# this export: a missing file still on the share from an earlier run, a file
# whose export failed (the summary's error count), and sidecars, which
# osxphotos writes without a history row (sidecars.py), if a config ever
# turns them on. The query reads only this export's history rows, with an
# index lookup for each, so its cost grows with the library, not with
# history, which gains a row per file every run.
mirror_from_export_db() {
    local result
    case "${history_mark:-}" in
        '' | *[!0-9]*) return 1 ;;
    esac
    export_db_read result "
        WITH this_export AS (
            SELECT filepath_id,
                max(action IN ('new', 'export', 'AAE: new', 'AAE: export')
                    OR action LIKE 'update: %' OR action LIKE 'AAE: update: %') AS written
            FROM history
            WHERE id > $history_mark AND action NOT IN ('missing', 'AAE: missing')
            GROUP BY filepath_id
        )
        SELECT count(*), coalesce(sum(e.dest_size), 0),
            coalesce(sum(CASE WHEN written THEN e.dest_size END), 0)
        FROM this_export
        JOIN history_path p ON p.id = this_export.filepath_id
        LEFT JOIN export_data e ON e.filepath_normalized = p.filepath_normalized;" || return 1
    case "$result" in
        *[!0-9\ ]* | '')
            export_db_error="sqlite3 printed '$result'"
            return 1
            ;;
    esac
    read -r mirror_files mirror_bytes export_bytes <<< "$result"
}

# gauge NAME HELP VALUE [LABELS]: a gauge's HELP and TYPE lines and one
# sample. Prints nothing if VALUE is empty.
gauge() {
    [ -n "$3" ] || return 0
    printf '# HELP %s%s %s\n# TYPE %s%s gauge\n%s%s%s %s\n' \
        "$METRICS_PREFIX" "$1" "$2" "$METRICS_PREFIX" "$1" "$METRICS_PREFIX" "$1" "${4:-}" "$3"
}

# carry NAME: metric NAME's lines from the textfile as it is, written by an
# earlier run, if they are whole: a HELP line, a TYPE line, then one or more
# samples, as this script writes them. Otherwise, or if it has none, nothing,
# and the metric is dropped until a run has a value for it.
carry() {
    local lines
    [ -f "$METRICS_TEXTFILE" ] || return 0
    lines=$(grep -E "^(# (HELP|TYPE) )?$METRICS_PREFIX$1( |\\{)" "$METRICS_TEXTFILE" 2> /dev/null) || return 0
    printf '%s\n' "$lines" | awk -v help="# HELP $METRICS_PREFIX$1 " -v type="# TYPE $METRICS_PREFIX$1 " '
        NR == 1 { whole = index($0, help) == 1 }
        NR == 2 { whole = whole && index($0, type) == 1 }
        NR > 2 { whole = whole && substr($0, 1, 1) != "#" }
        END { exit !(whole && NR >= 3) }' || return 0
    printf '%s\n' "$lines"
}

# summary_count PATTERN: the number sed PATTERN (with \(N\) for it) finds in
# this run's export summary, from export_summary. Empty if none.
summary_count() {
    printf '%s\n' "${export_summary_text:-}" | sed -n "s/$1/\\1/p" | head -n 1
}

# metrics_text OUTCOME: the textfile for a run that ended OUTCOME. Each
# metric is this run's value where this run has one; otherwise its lines are
# carried over from the textfile an earlier run wrote:
# - the run's time and outcome, the last-ok stamp and the export database's
#   size: every run.
# - the run's duration: every run but a skipped one.
# - the export's time, duration and osxphotos' summary counts: a run whose
#   export printed its summary.
# - the mirror's files and bytes and the bytes written: an ok run (see
#   mirror_from_export_db).
metrics_text() {
    local entry name value result files
    gauge last_run_timestamp_seconds "When the last run ended, in seconds since the epoch." "$(date +%s)"
    printf '# HELP %slast_run_outcome %s\n# TYPE %slast_run_outcome gauge\n' "$METRICS_PREFIX" \
        "The last run's outcome: 1 for the outcome it ended with, 0 for every other." "$METRICS_PREFIX"
    for entry in $OUTCOMES; do
        name=${entry%:*}
        value=0
        [ "$name" != "$1" ] || value=1
        printf '%slast_run_outcome{outcome="%s"} %s\n' "$METRICS_PREFIX" "$name" "$value"
    done
    if [ -e "${STAMP:-}" ]; then
        gauge last_ok_timestamp_seconds "When the last ok run ended (the last-ok stamp's mtime), in seconds since the epoch." \
            "$(stat -f %m "$STAMP")"
    fi
    case "$1" in
        skipped-*) carry last_run_duration_seconds ;;
        *) gauge last_run_duration_seconds "How long the last run that wasn't skipped took, in seconds." "$SECONDS" ;;
    esac
    if [ -n "${export_summary_text:-}" ]; then
        gauge last_export_timestamp_seconds "When the last export that printed its summary ended, in seconds since the epoch." \
            "$export_ended_at"
        gauge last_export_duration_seconds "How long the last export that printed its summary took, in seconds." \
            "$((export_ended - export_started))"
        gauge last_export_photos "Photos the last export processed, from osxphotos' summary." \
            "$(summary_count '.*Processed: \([0-9][0-9]*\) photo.*')"
        files=
        for result in exported updated skipped missing error; do
            value=$(summary_count ".*, $result: \\([0-9][0-9]*\\).*")
            [ -z "$value" ] || files="$files${METRICS_PREFIX}last_export_files{result=\"$result\"} $value
"
        done
        if [ -n "$files" ]; then
            printf '# HELP %slast_export_files %s\n# TYPE %slast_export_files gauge\n%s' "$METRICS_PREFIX" \
                "Files in the last export, by what osxphotos did with them, from its summary." "$METRICS_PREFIX" "$files"
        fi
        gauge last_export_deleted_files "Files the last export's cleanup deleted from the share." \
            "$(summary_count '.*Deleted: \([0-9][0-9]*\) file.*')"
    else
        for name in last_export_timestamp_seconds last_export_duration_seconds last_export_photos \
            last_export_files last_export_deleted_files; do
            carry "$name"
        done
    fi
    if [ -f "${OSXPHOTOS_EXPORT_DB:-}" ]; then
        gauge export_db_bytes "The export database's size, in bytes." "$(stat -f %z "$OSXPHOTOS_EXPORT_DB")"
    fi
    if [ -n "${mirror_files:-}" ]; then
        gauge mirror_files "Files on the share as of the last ok run: those its export wrote or found up to date." "$mirror_files"
        gauge mirror_bytes "The size of the files in mirror_files, as osxphotos last wrote them, in bytes." "$mirror_bytes"
        gauge last_export_bytes "Bytes the last ok run's export wrote: new and updated files." "$export_bytes"
    else
        for name in mirror_files mirror_bytes last_export_bytes; do
            carry "$name"
        done
    fi
}

# write_metrics OUTCOME: if METRICS_TEXTFILE is set, write it for a run that
# ended OUTCOME. It is written whole to a temp file beside it, which
# node_exporter ignores (its name doesn't end .prom), then renamed over it,
# so node_exporter never reads half a file. A write that fails leaves the
# textfile as it was, removes the temp file and is a warning.
write_metrics() {
    local tmp text
    # Before the conf is checked, a relative path may still be set; it is
    # never written (see the check after the conf is loaded).
    case "${METRICS_TEXTFILE:-}" in
        /*) ;;
        *) return 0 ;;
    esac
    tmp="$METRICS_TEXTFILE.$$.tmp"
    # The text is made in memory and written with one printf, whose status
    # is checked, so a short write (a full disk, say) is never renamed over
    # the textfile.
    text=$(metrics_text "$1")
    if ! { printf '%s\n' "$text" > "$tmp" && [ ! -d "$METRICS_TEXTFILE" ] &&
        mv -f "$tmp" "$METRICS_TEXTFILE"; } 2> /dev/null; then
        rm -f "$tmp" 2> /dev/null
        log "WARNING: Could not write the metrics textfile $METRICS_TEXTFILE."
    fi
}

# finish OUTCOME: end the run. Every run ends here, with one outcome=<name>
# line as the last line of the run log and the outcome's exit code (sysexits.h).
# A failing run's notification names the log that explains it: an outcome
# that stopped or followed an export names that export's log, any other the
# run log. Then the metrics textfile is written, if the conf sets one. The
# run log is trimmed last, so the outcome line is never cut. A run that
# finds the lock held doesn't trim: the run holding it may be writing to the
# run log, and trims it when it ends.
finishing=
finish() {
    local code entry see
    finishing=$1
    code=
    for entry in $OUTCOMES; do
        [ "${entry%:*}" != "$1" ] || code=${entry#*:}
    done
    if [ -z "$code" ]; then
        # A misspelt outcome is a bug in this script: EX_SOFTWARE.
        log "ERROR: finish called with unknown outcome '$1'."
        code=70
    fi
    if [ "$code" -ne 0 ]; then
        see=${LOG_FILE:-}
        case "$1" in
            export-failed | share-lost | interrupted) see=${export_log:-$see} ;;
        esac
        if [ -n "$see" ]; then
            notify "Mirror run failed: $1. See $see."
        else
            notify "Mirror run failed: $1. See this run's error output (under launchd, the run log)."
        fi
    fi
    write_metrics "$1"
    if [ -n "${LOG_FILE:-}" ] && [ "$1" != skipped-locked ]; then
        trim_run_log
    fi
    log "outcome=$1"
    exit "$code"
}

# This script's own directory, as an absolute path, found once. $0 may be
# bare or relative (`bash osxphotos-nas-mirror.sh`). pwd -P and a cd in a
# subshell work in macOS's bash 3.2, which has no realpath.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)

# When this run started, which names its export log: sortable, and with no
# colons, which Finder shows as slashes.
RUN_STARTED=$(date '+%Y-%m-%dT%H-%M-%S')

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
        # The run log may be the missing setting, so report on stderr.
        LOG_FILE=
        log "ERROR: Configuration file $CONF does not set $setting."
        finish usage-error
    fi
done

# Ensure the application support directory exists
mkdir -p "$APP_DIR"
# The last-ok stamp (see the recency gate), which the metrics read too.
STAMP="$APP_DIR/last-ok"

# METRICS_TEXTFILE in the conf (optional) must be an absolute path, as
# LOCK_FILE must. A relative one is a warning, not a usage-error, since the
# metrics never change a run's outcome; the run writes no textfile.
case "${METRICS_TEXTFILE:-/}" in
    /*) ;;
    *)
        log "WARNING: METRICS_TEXTFILE in $CONF is '$METRICS_TEXTFILE', which is not an absolute path. Writing no metrics."
        METRICS_TEXTFILE=
        ;;
esac

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
# print "Terminated" on stderr, which under launchd is the run log, hence the
# 2> /dev/null on wait. osxphotos is uv's child, not ours, so it is waited for
# by polling, for up to 5 seconds; one that outlives that keeps the lock.
# (launchd sends SIGKILL ExitTimeOut seconds after SIGTERM, 20 by default,
# and finish may still need NOTIFY_TIMEOUT seconds after this.)
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
    log_export_summary
}

# export_summary FILE: print osxphotos' closing lines from the export log
# FILE, the last of each: the summary, "Processed: N photos, exported: N,
# updated: N, skipped: N, updated EXIF data: N, missing: N, error: N, touched
# date: N", and, if it cleaned up, "Deleted: N files, N directories". That is
# how osxphotos/cli/export.py (at the pinned tag) prints them through rich to
# a file: markup stripped, one line each. They aren't anchored to the start
# of the line, so osxphotos' --timestamp would not hide them. Fails if there
# is no summary line.
export_summary() {
    local summary
    summary=$(grep -E 'Processed: [0-9]+ photos?, exported: [0-9]+' "$1" 2> /dev/null | tail -n 1)
    [ -n "$summary" ] || return 1
    printf '%s\n' "$summary"
    grep -E 'Deleted: [0-9]+ files?, [0-9]+ director' "$1" 2> /dev/null | tail -n 1
}

# log_export_summary: once osxphotos has exited, however it ended, copy its
# closing lines from the export log into the run log, or say there were
# none. Once a run. It also notes, for the metrics, when the export ended
# and the summary (export_summary_text).
log_export_summary() {
    local summary line
    [ -n "${export_log:-}" ] && [ -z "${summary_logged:-}" ] || return 0
    summary_logged=yes
    export_ended=$SECONDS
    export_ended_at=$(date +%s)
    if summary=$(export_summary "$export_log"); then
        export_summary_text=$summary
        while IFS= read -r line; do
            log "osxphotos: $line"
        done <<< "$summary"
    else
        log "osxphotos printed no summary line in $export_log."
    fi
}

# prune_export_logs: delete the oldest export logs, so that with this run's
# there are EXPORT_LOGS_KEPT. Their names sort by time. Only files named as
# export logs are touched; one that can't be deleted is a warning.
prune_export_logs() {
    local logs extra i
    logs=("$EXPORT_LOG_DIR"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]-[0-9][0-9]-[0-9][0-9].log)
    [ -e "${logs[0]}" ] || return 0
    extra=$((${#logs[@]} - (EXPORT_LOGS_KEPT - 1)))
    i=0
    while [ "$i" -lt "$extra" ]; do
        rm -f "${logs[$i]}" || log "WARNING: Could not delete the old export log ${logs[$i]}."
        i=$((i + 1))
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

# osxphotos' output, stdout and stderr, a line or two a photo with verbose =
# true, goes to this run's export log in exports/, not to the run log, which
# gets a line naming it and, once osxphotos exits, its summary. Before the
# new export log is written, the oldest are deleted.
EXPORT_LOG_DIR="$APP_DIR/exports"
if ! mkdir -p "$EXPORT_LOG_DIR"; then
    log "ERROR: Cannot create $EXPORT_LOG_DIR for the export log."
    finish export-failed
fi
prune_export_logs
export_log="$EXPORT_LOG_DIR/$RUN_STARTED.log"
log "Export log: $export_log"

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
# In the app, a Python with that pin is beside the script, and it runs that
# unless the conf names a source. -B: a .pyc would break the app's signature.
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
# For the metrics: where this export's history rows will start (see
# mirror_from_export_db). A new export database has none yet.
if [ -n "${METRICS_TEXTFILE:-}" ]; then
    if [ -e "$OSXPHOTOS_EXPORT_DB" ]; then
        export_db_read history_mark 'SELECT coalesce(max(id), 0) FROM history;' || history_mark=
    else
        history_mark=0
    fi
fi
export_started=$SECONDS
default_osxphotos_source=git+https://github.com/TimJDFletcher/osxphotos@27c2f9d68e924770ecdc6cdc902d0737f3a16fee
if [ -z "${OSXPHOTOS_SOURCE:-}" ] && [ -x "$SCRIPT_DIR/python/bin/python3.13" ]; then
    osxphotos=("$SCRIPT_DIR/python/bin/python3.13" -B -m osxphotos)
else
    osxphotos=(uvx --python 3.13 --from "${OSXPHOTOS_SOURCE:-$default_osxphotos_source}" osxphotos)
fi
"${osxphotos[@]}" export \
    --newest-first \
    --load-config "${OSXPHOTOS_CONFIG:-$SCRIPT_DIR/osxphotos.toml}" \
    --exportdb "$OSXPHOTOS_EXPORT_DB" "$EXPORT_DIR" > "$export_log" 2>&1 &
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
log_export_summary
if [ "$export_rc" -ne 0 ]; then
    log "ERROR: The export failed (osxphotos exited $export_rc). See $export_log."
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
if [ -n "${METRICS_TEXTFILE:-}" ] && ! mirror_from_export_db; then
    log "WARNING: Could not read the mirror's files and size from the export database $OSXPHOTOS_EXPORT_DB (${export_db_error:-no history mark from before the export}); the metrics keep the last ok run's."
fi
log "Mirror run finished."
finish ok
