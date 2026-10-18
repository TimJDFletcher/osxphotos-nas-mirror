# osxphotos-nas-mirror

Mirrors a Mac's Photos library to an SMB share on a NAS with osxphotos, unattended under launchd. It was called `icloud-photos-backup` before; old notes, issues and the local directory name may still use that.

Read `GLOSSARY.md` first and use its terms (run, outcome, preflight check, run log, export log, metrics textfile, run lock, share, mirror, archive, export database). Read the `docs/adr/` entries for the area you touch: they hold the reasons behind the mounting, the export database, the osxphotos pin, the mirror, the keychain check and the run lock. README.md is the user's manual (outcomes table, setup); don't copy it here.

## Layout

- `osxphotos-nas-mirror.sh`: the whole tool. Sources the conf, takes `--skip-preflight-check` or `--force` (both skip every check), takes the run lock (a `flock`, through `perl`, on descriptor 9, which osxphotos inherits, so the lock outlives a killed script while its export runs; on `LOCK_FILE`, default `$APP_DIR/run.lock`; a held lock ends `skipped-locked`; ADR 0006), traps SIGTERM, SIGINT and SIGHUP (stops the export, ends `interrupted`), applies the recency gate (a `$APP_DIR/last-ok` stamp younger than `MIRROR_INTERVAL_DAYS` x 24 hours, default 7 (`find -mtime -N`: the gate opens when the stamp is exactly N x 24 hours old, not at a calendar-day boundary), ends `skipped-recent`; only an `ok` run touches it; `--force` bypasses it), runs the preflight checks, mounts the share, runs osxphotos under a watchdog, copies the export database to the share.
- `osxphotos-nas-mirror.conf.example`: every setting. The real conf is `~/Library/Application Support/osxphotos-nas-mirror/osxphotos-nas-mirror.conf` (gitignored); `OSXPHOTOS_NAS_MIRROR_CONF` overrides the path.
- App dir (`APP_DIR`), same location: the run log `osxphotos-nas-mirror.log` (`LOG_FILE`; the script's lines, preflight check and mount output, a line naming the export log and osxphotos' summary; `finish` trims it to its last 10,000 lines, except on `skipped-locked`), `exports/` (one export log per run that exported, osxphotos' stdout and stderr, named after the run's start time, `YYYY-MM-DDTHH-MM-SS.log`; the 8 newest are kept), `osxphotos_export.db`, the `last-ok` stamp and `run.lock`. Both limits are constants in the script. `export_summary` finds osxphotos' summary and cleanup lines in an export log.
- The metrics textfile, `METRICS_TEXTFILE` (optional, wherever node_exporter's textfile collector looks, not in the app dir), is written by `finish` on every outcome; metrics a run has no value for are carried over from the file as it was, and `mirror_files`/`mirror_bytes` come from the export database's `history` rows for the export, read with `sqlite3 -readonly` (`mirror_from_export_db` says why not `export_data`).
- `osxphotos.toml`: the osxphotos config the script loads (`OSXPHOTOS_CONFIG` overrides). `examples/osxphotos-exif.toml` is an unused alternative.
- `preflight-checks/{dock-connected,network-path,download-speed,nas-rtt}.sh`: example checks. `PREFLIGHT_CHECKS` in the conf is an array of strings, each a command and arguments split on whitespace; a relative path resolves against the script's directory. They run in order and the first that doesn't exit 0 decides: 1 ends `skipped-preflight-check`, anything else ends `preflight-check-failed`.
- `launchd/*.plist.template`: `make install` fills it in and copies it to `~/Library/LaunchAgents` (label `io.github.timjdfletcher.osxphotos-nas-mirror`, on the hour every hour (`StartCalendarInterval`; the script's own 7 x 24-hour gate makes the mirror weekly), stdout to `/dev/null` because the script logs its own lines, stderr to the run log, `PATH` including `/opt/homebrew/bin` for `uv`). It doesn't run `launchctl`.

## Outcomes

Every run ends through `finish`, which sends a macOS notification on a non-zero code (naming the export log for `export-failed`, `share-lost` and `interrupted` once the export has started, else the run log), writes the metrics textfile (`METRICS_TEXTFILE`, if set; a failed write is a warning), trims the run log and logs `outcome=<name>` as its last line. The set of outcomes is fixed. `OUTCOMES`, beside `finish`, holds the names and exit codes, and the textfile has an outcome series for each; the README ("Outcomes") has the table. Add or rename one in both, and in the tests (`all_outcomes` in `tests/mirror-run.sh` too).

## Rules

- Before editing `osxphotos-nas-mirror.sh`, check no run is in progress: `ps -ax | grep -E '[o]sxphotos-nas-mirror|[o]sxphotos export'`. Editing a running script corrupts that run. If one is listed, wait or tell the user.
- Never run the script against the real conf from a test or an experiment: the stubs would write a fake export database over the real one. Tests set `OSXPHOTOS_NAS_MIRROR_CONF`.
- The owner runs real runs. Mounts and keychain access fail or are blocked from an agent's shell, so test with the stubs and leave real runs to the user.
- Don't raise a password dialog (ADR 0005). The tool never saves passwords; the user does it once in Finder.
- Quote the osxphotos fork tag (`vX.Y.Z-tim.N`) only in `osxphotos-nas-mirror.sh` and `tests/mirror-run.sh`. Renovate (`renovate.json`) bumps those two and reads only that tag scheme, so a copy elsewhere goes stale.

## What the Samba server needs

README ("Prerequisites") is the user-facing copy; keep the two in agreement. When a share misbehaves, check:

- `vfs objects = catia fruit streams_xattr`, with `fruit:metadata = stream`, `fruit:encoding = native`, `fruit:resource = xattr` and `fruit:aapl = yes`.
- The share is writable by the SMB user and has `inherit permissions = yes`. Without it osxphotos can create directories but not write files in them ("Permission denied", code 513).
- `server min protocol = SMB2`.
- The share is case-insensitive to SMB2 clients. Samba's default `case sensitive = auto` does that, even on a case-sensitive filesystem. osxphotos' `--cleanup` compares names case-insensitively.
- The author's NAS is ZFS, and snapshots build the archive (ADR 0004). Nothing in the tool depends on ZFS.

## Tests

`make test` runs shellcheck, plutil on a filled-in template, then `tests/mirror-run.sh`, `tests/preflight-checks.sh` and `tests/install.sh`; CI runs the same on macOS (`.github/workflows/test.yml`). The tests run the script or check as a process with stub commands first on `PATH` and assert only on the exit code, the outcome line, the stubs' recorded arguments and the files written. Fixtures are in `tests/fixtures/`. Shell is POSIX `sh` in tests and preflight checks, bash in the script.

## Why the osxphotos setup is the way it is

The ADRs hold the reasons for the big choices: the mount (0001), the export database on the SSD and no `--ramdb` (0002), uvx and the fork pin (0003), `cleanup = true` and the mirror (0004), the run lock that the export inherits (0006). What they don't hold:

- No `--limit`: it caps one run's photo count and gives no resumption. Resumption comes from `update = true` and the export database. The script exports the whole library in one run, newest first.
- No `overwrite` in `osxphotos.toml`: in update mode it only changes what happens when two photos map to the same file name (the second overwrites the first instead of becoming `name (1).ext`).
- The export path is the command line argument, not in the config, because the mount point is found at run time.
- `cleanup` compares names case-insensitively, so the share must be case-insensitive to SMB clients; Samba's default `case sensitive = auto` is.
- osxphotos runs in the background under a watchdog: every `SHARE_CHECK_INTERVAL` seconds (default 5) the share must still be mounted where the export started, and once more after the export, or osxphotos is stopped and the run ends `share-lost` without copying the database. osxphotos itself logs a failed write and exits 0, so only the watchdog catches a dropped share.
- No unified log (`logger`, `os_log`): `logger` writes with no subsystem or category and drops its `-t` tag, a subsystem would need a compiled helper, and the unified log store on the author's Mac kept less than a day, too short for a weekly run's outcome. The run log and the export logs are plain files the script bounds itself.
- Changes to the osxphotos pin go through Renovate or the two files named under Rules (`CONTRIBUTING.md`, "For the maintainer").

## Agent skills

- Issue tracker: GitHub issues, `docs/agents/issue-tracker.md`.
- Triage labels: the five canonical role names plus a few extras, `docs/agents/triage-labels.md`.
- Domain docs: single-context, `docs/agents/domain.md`.
