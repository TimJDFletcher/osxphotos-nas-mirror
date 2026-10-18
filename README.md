# osxphotos-nas-mirror

Mirrors the Photos library on a Mac to an SMB share on a NAS, using [osxphotos](https://github.com/RhetTbull/osxphotos). It is a weekly mirror: a launchd agent starts it every hour, and the script skips the run unless the last good one finished at least seven full days (7 x 24 hours) ago.

Preflight checks decide whether each run goes ahead. One of the example preflight checks, the dock check, lets a run start only while the Mac is plugged into a given Ethernet dock, identified by the dock's MAC address. That keeps a laptop from running away from home.

The share holds a mirror of the library, not a backup on its own. A backup also needs an archive, the history of the mirror, which you build outside this tool (see `docs/adr/0004-the-share-is-a-mirror.md`).

## How it works

* The source is the local Photos library (the System Library).
* The destination is the share, mounted the way Finder mounts it, under `/Volumes` (usually `/Volumes/photos`; see `docs/adr/0001-mount-the-share-as-finder-does.md`).
* osxphotos runs through `uv` for the export, AppleScript's `mount volume` does the mount, and `launchd` does the scheduling.
* The osxphotos export database stays on the Mac's SSD in `~/Library/Application Support/osxphotos-nas-mirror/`. After each successful run the script copies it to the share as `.osxphotos_export.db`.

## Files

| File | Purpose |
|---|---|
| `osxphotos-nas-mirror.sh` | The mirror script: preflight checks, mount, export, database copy. |
| `osxphotos-nas-mirror.conf.example` | The settings, with placeholder NAS details. Copy it to the app directory as `osxphotos-nas-mirror.conf`; the script sources that copy. |
| `osxphotos.toml` | The osxphotos export options the script loads. |
| `preflight-checks/dock-connected.sh` | The dock check, one of the example preflight checks. `dock-connected.sh MAC` exits 0 if that MAC address appears in `ifconfig -a`, 1 if not, 2 if given no address. |
| `preflight-checks/network-path.sh` | Skips the run on a hotspot or cellular connection, in Low Data Mode, or offline. Runs `network-path.swift` with `swift`, so it needs the Xcode command line tools. |
| `preflight-checks/download-speed.sh` | `download-speed.sh MIN_MBIT` skips the run if `networkQuality` measures the download below MIN_MBIT. Each test moves a few hundred MB (about 215 MB in the fixture), so list it after `network-path.sh` and it won't run on a hotspot. With the weekly gate it runs at most once an hour, and only while the gate is open. A run downloads missing originals from iCloud, and `networkQuality` measures the path to Apple's servers, so this covers the iCloud side. `nas-rtt.sh` covers the NAS side. |
| `preflight-checks/nas-rtt.sh` | `nas-rtt.sh HOST MAX_MS` skips the run unless HOST answers a ping with an average round trip of at most MAX_MS. Suits a NAS on the home LAN. |
| `examples/osxphotos-exif.toml` | An alternative config that also writes metadata with exiftool, XMP sidecars and Finder tags. The script doesn't use it; point `OSXPHOTOS_CONFIG` at a copy to use it. |
| `launchd/io.github.timjdfletcher.osxphotos-nas-mirror.plist.template` | The launchd agent that runs the script, with `@REPO@` and `@HOME@` placeholders that `make install` fills in. |

## Prerequisites

1.  A Mac running macOS, with Photos set to "Download Originals" or able to download them on demand (the config sets `download_missing`).
2.  `uv` and `git`. Install uv with `brew install uv`; git comes with the Xcode command line tools. The script runs osxphotos through uv, as `uvx --python 3.13 --from git+https://github.com/TimJDFletcher/osxphotos@<tag> osxphotos`, so osxphotos gets its own Python environment. uv clones and builds it on the first run, which takes a while. Homebrew's osxphotos formula doesn't work for this: it broke when Homebrew's `cffi` dropped Python 3.13 (`No module named '_cffi_backend'`).

    The default osxphotos source is a pinned tag of the author's fork, which fixes two bugs in 0.77.2 (see `docs/adr/0003-run-osxphotos-through-uvx-from-a-pinned-source.md`). `OSXPHOTOS_SOURCE` in the conf overrides it, for example with `osxphotos==0.77.2` from PyPI.
3.  A Samba server with the macOS VFS modules enabled. In `smb.conf`:
    ```ini
    [global]
    vfs objects = catia fruit streams_xattr
    fruit:metadata = stream
    fruit:encoding = native
    fruit:resource = xattr
    fruit:aapl = yes
    server min protocol = SMB2
    ```
    The share must be writable by the SMB user. The author's share also sets `inherit permissions = Yes`, which fixed a "Permission denied" (code 513) where osxphotos could create folders but not write files in them. Samba's default `case sensitive = auto` makes the share case-insensitive to SMB2 clients, which osxphotos' `--cleanup` expects, even on a case-sensitive filesystem.

## Setup

1.  Clone this repo:
    ```bash
    git clone https://github.com/TimJDFletcher/osxphotos-nas-mirror.git
    cd osxphotos-nas-mirror
    ```

2.  Copy the example conf to the app directory and edit it. The real conf isn't in the repo (`*.conf` is gitignored):
    ```bash
    mkdir -p ~/Library/Application\ Support/osxphotos-nas-mirror
    cp osxphotos-nas-mirror.conf.example ~/Library/Application\ Support/osxphotos-nas-mirror/osxphotos-nas-mirror.conf
    ```
    `OSXPHOTOS_NAS_MIRROR_CONF` overrides the path. The settings you will change:
    * `NAS_USER`, `NAS_HOSTNAME`, `NAS_SHARE`: the SMB user, server and share.
    * `MOUNT_TIMEOUT`: seconds to wait for the share to mount (default 60).
    * `SHARE_CHECK_INTERVAL`: seconds between checks that the share is still mounted while osxphotos exports (default 5).
    * `MIRROR_INTERVAL_DAYS` (optional): the least number of days between good runs (default 7). It counts whole 24-hour periods from the last good run, not calendar days: the gate opens when that run is `MIRROR_INTERVAL_DAYS` x 24 hours old, and the next hourly start after that runs. 0 runs every time the agent starts it.
    * `PREFLIGHT_CHECKS` (optional): a bash array of strings, one per check, run in order before anything is mounted. Each string is split on whitespace into a command and its arguments, so an argument can't contain a space. The first check that doesn't exit 0 decides and later ones don't run: exit 1 ends the run `skipped-preflight-check`, and any other code ends it `preflight-check-failed`. If every check exits 0 the run goes ahead. A command path containing a `/` that isn't absolute is relative to the script's directory. Unset or empty, every run goes ahead. For example, `PREFLIGHT_CHECKS=("preflight-checks/network-path.sh" "preflight-checks/download-speed.sh 50")`. For the dock check, use the MAC address of the dock's Ethernet adapter, found in `ifconfig -a` while docked: `PREFLIGHT_CHECKS=("preflight-checks/dock-connected.sh aa:bb:cc:dd:ee:ff")`.
    * `OSXPHOTOS_SOURCE` (optional): what `uvx --from` installs osxphotos from, such as `osxphotos==0.77.2` or `git+https://...@<tag>`. Unset, the script's pinned default is used. Python stays 3.13.
    * `OSXPHOTOS_CONFIG` (optional): the osxphotos TOML to load. Unset, the repo's `osxphotos.toml`.
    * `LOCK_FILE` (optional): the run lock's file (see "Outcomes", `skipped-locked`). Unset, `osxphotos-nas-mirror.lock` in your per-user temporary directory (`getconf DARWIN_USER_TEMP_DIR`), which macOS empties at boot. Its directory must be yours and writable by nobody else, or the run ends `usage-error`.

    On a laptop, set a preflight check. `nas-rtt.sh` needs no MAC address and no swift; use the dock check if you dock. Without one, every hourly attempt away from home, once the weekly gate opens, ends `mount-failed` with a notification.

    The example also sets `NOTIFY_TIMEOUT`, `APP_DIR`, `LOG_FILE` and `OSXPHOTOS_EXPORT_DB`. The defaults are fine.

3.  Save the SMB password the Finder way. In Finder choose Go > Connect to Server, enter `smb://NAS_USER@NAS_HOSTNAME/NAS_SHARE` with your values from the conf, type the password and tick "Remember this password in my keychain". Each run checks the login keychain before mounting and ends in `no-credentials` if there is no entry, so a run never raises a password dialog.

4.  Give the program that runs the script Full Disk Access, so osxphotos can read the Photos library. Run by hand, that is your terminal app. Run by launchd, it is `/bin/bash`, which is what launchd runs the script with. In System Settings > Privacy & Security > Full Disk Access, click +, press Cmd+Shift+G, type `/bin/bash` and add it.

5.  Run it once by hand with `--force` (see Usage). The first run mirrors the whole library, so it takes a long time.

6.  Install the launchd agent (see Automation).

## Usage

First run, or any run started by hand:
```bash
./osxphotos-nas-mirror.sh --force
```

What launchd runs:
```bash
./osxphotos-nas-mirror.sh
```

The script takes at most one flag:

* `--force` skips the recency gate and every preflight check. Use it for a run you start by hand, such as the first one, or one soon after a good run.
* `--skip-preflight-check` skips only the preflight checks; the recency gate still applies.

Without a flag, the script first checks the stamp (see Automation), then runs the conf's `PREFLIGHT_CHECKS` in order. If one exits 1, as the dock check does when the dock is absent, the run ends quietly and the later ones don't run.

Watch the log:
```bash
tail -f "$HOME/Library/Application Support/osxphotos-nas-mirror/osxphotos-nas-mirror.log"
```

## Automation

The launchd agent starts the script on the hour, every hour (`StartCalendarInterval`, `Minute` 0), so a Mac that is home at any hour is caught. A LaunchAgent runs only while you are logged in and the Mac is awake. Hourly runs missed while it slept coalesce into one run on wake.

The script makes that weekly. A run that ends `ok` touches `last-ok` in the app directory. Until that file is `MIRROR_INTERVAL_DAYS` x 24 hours old (default 7 days, so 168 hours), a run ends `skipped-recent`, before the preflight checks, so a costly check such as `download-speed.sh` doesn't run while the gate is shut. Once it opens, a check that skips the run is tried again each hour. With no `last-ok` the run goes ahead. Only `ok` writes it: a failed or skipped run is tried again at the next hour. A preflight check such as the dock check makes runs a no-op away from home.

```bash
make install
launchctl load ~/Library/LaunchAgents/io.github.timjdfletcher.osxphotos-nas-mirror.plist
launchctl list | grep io.github.timjdfletcher.osxphotos-nas-mirror
```

`make install` fills in the template with the path of this checkout and your home directory, and copies the result to `~/Library/LaunchAgents/`. It doesn't run `launchctl`; it prints the `load` command. Run `make install` again if you move the checkout, then `launchctl unload` and `launchctl load` the plist, because launchd keeps the copy it loaded. The plist sets `PATH` to include `/opt/homebrew/bin`, because launchd's default `PATH` doesn't reach Homebrew's `uv`. On an Intel Mac, where Homebrew lives in `/usr/local/bin`, edit the plist's `PATH`. stdout goes to `/dev/null` because the script already writes each line to the log; stderr goes to the log.

The log grows without bound, because `osxphotos.toml` sets `verbose = true`, which logs a line per photo. To keep it small, set `verbose = false` in a copy of `osxphotos.toml` and point `OSXPHOTOS_CONFIG` at the copy, or delete the log now and then between runs. (newsyslog can't rotate it: its config splits fields on spaces, and the log's path has one.)

## Outcomes

Every run ends with one `outcome=<name>` line as the last line of its log, and exits with that outcome's code (from `sysexits.h`):

| Outcome | Exit | Meaning |
|---|---|---|
| `ok` | 0 | Exported, and the export database was copied to the share. |
| `skipped-preflight-check` | 0 | A preflight check exited 1: this run is not wanted (for the dock check, the dock is absent). The log names the check. Later checks did not run. Nothing was mounted or exported. |
| `skipped-recent` | 0 | The last good run was less than `MIRROR_INTERVAL_DAYS` x 24 hours ago (see Automation). The log says when. Nothing was mounted or exported, and the preflight checks did not run. `--force` bypasses this. |
| `skipped-locked` | 0 | Another run, or the export of one, was still in progress. A run holds a kernel lock (`flock`) on `LOCK_FILE` (by default `osxphotos-nas-mirror.lock` in the per-user temporary directory), and osxphotos inherits it, so the lock stays held while the export runs, even if the script that started it was killed. A reboot clears it. Nothing was mounted or exported. |
| `usage-error` | 64 | An unknown argument, a `MIRROR_INTERVAL_DAYS` that is not a whole number, or a conf that is missing, unreadable, fails to load, or leaves a setting unset, or a lock file that can't be opened or locked, or whose directory is missing, not yours, or writable by others. Nothing was mounted or exported. |
| `mount-failed` | 69 | The share was not mounted after trying to mount it. |
| `share-lost` | 69 | The share stopped being mounted during the export or before the database copy. osxphotos was stopped and the database was not copied. |
| `preflight-check-failed` | 70 | A preflight check exited 2 or more, or could not be run (bash's 126 and 127). The log names the check and the code. Later checks did not run. Nothing was mounted or exported. |
| `export-failed` | 70 | `osxphotos export` exited non-zero. The export database was not copied to the share. |
| `db-copy-failed` | 74 | The export succeeded, but copying the export database to the share failed. |
| `interrupted` | 75 | The run was stopped by SIGTERM (as launchd sends when the agent is unloaded or you log out), SIGINT (Ctrl-C) or SIGHUP. osxphotos was stopped and the export database was not copied. The next run picks up where this one stopped. |
| `no-credentials` | 78 | The share needed mounting, but the login keychain has no SMB password for `NAS_USER` at `NAS_HOSTNAME`. Nothing was mounted or exported. Connect to the share once in Finder and tick "Remember this password in my keychain". |

Every outcome with a non-zero exit code also posts a macOS notification titled "osxphotos NAS mirror" (`Mirror run failed: <outcome>. See <log file>.`, or, with no log file, a pointer to the run's error output), through `osascript`. `ok`, `skipped-preflight-check`, `skipped-recent` and `skipped-locked` post none. If the notification can't be posted, or `osascript` takes longer than `NOTIFY_TIMEOUT` seconds (conf, default 10), the run logs a warning and its outcome is unchanged.

When the conf is missing or unreadable, or leaves a setting unset, the run's lines, including the outcome, go to stderr instead of the log file.

Upgrading from a version that used `lockf`: the run lock is no longer `run.lock` in the app directory. Nothing uses that file now, and you can delete it.

### Checking notifications

The tests stub `osascript`, so they can't show that macOS displays a notification posted from a LaunchAgent, and `osascript` exits 0 even when macOS suppresses one. Check by hand, logged in at the Mac:

```bash
launchctl submit -l io.github.timjdfletcher.osxphotos-nas-mirror.notify-test -- /bin/sh -c \
  '/usr/bin/osascript -e "display notification \"LaunchAgent test\" with title \"osxphotos NAS mirror\""; launchctl remove io.github.timjdfletcher.osxphotos-nas-mirror.notify-test'
```

A "LaunchAgent test" notification should appear once. `launchctl submit` restarts a job each time it exits, so this one removes itself after posting. If notifications keep coming, run `launchctl remove io.github.timjdfletcher.osxphotos-nas-mirror.notify-test`. If it doesn't, check System Settings > Notifications for Script Editor, which macOS shows as the sender of `osascript` notifications, and allow it.

## Tests

```bash
make test    # shellcheck, then the fixture tests and the make install test
```

`tests/mirror-run.sh` runs `osxphotos-nas-mirror.sh` as a process against a test conf (`OSXPHOTOS_NAS_MIRROR_CONF`) and stub `mount`, `uvx`, `osascript` and `security` on `PATH` (`osascript` stands in for both notifications and the mount), and stub preflight check scripts for each exit path and for several checks in a row, so no test touches the dock, the share or the Photos library. The example dock check is run as a process too, with a stub `ifconfig`. `tests/install.sh` runs `make install` with `HOME` set to a temporary directory and checks the plist it writes.

## Behaviour to know about

* The mirror follows deletions. `osxphotos.toml` sets `cleanup = true`, so a photo deleted from the library is deleted from the share on the next run.
* Updates are incremental. `update = true` exports only new or changed photos, using the export database. Keep that database: without it, osxphotos re-exports everything.
* The script passes `--newest-first`, so recent photos are mirrored first.

## License

GPL-3.0-or-later. Copyright (C) 2026 Tim Fletcher. See `LICENSE`.

## Issues

The backlog is on GitHub: [TimJDFletcher/osxphotos-nas-mirror issues](https://github.com/TimJDFletcher/osxphotos-nas-mirror/issues).
