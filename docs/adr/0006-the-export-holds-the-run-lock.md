# The export holds the run lock, in a file emptied at boot

One run at a time, and one export. The script takes an exclusive kernel lock (`flock`) on the lock file through a descriptor that every command it starts inherits, uv and osxphotos included. A `flock` lock belongs to the open file, and every process that holds a descriptor for it keeps it, so the lock stays held while osxphotos runs, even if the script is killed. A run that can't take it at once ends `skipped-locked`. macOS has no `flock` command, so a short `perl` call takes the lock on the inherited descriptor. uv passes the descriptor on: `lsof` on the python that `uvx … osxphotos` starts shows it open.

A run stopped by SIGTERM, SIGINT or SIGHUP stops osxphotos as the share watchdog does and ends `interrupted`. SIGKILL can't be trapped, and the lock covers it.

The lock file is in the per-user temporary directory (`getconf DARWIN_USER_TEMP_DIR`), which macOS empties at boot, so a reboot always clears a broken lock. It is the user's own, mode 0700. `getconf` looks it up for the user, not from `TMPDIR`, so a LaunchAgent and a terminal get the same one. macOS also deletes files there that are a few days old, and the first export of a large library can take days, so the share watchdog touches the lock file at each check. The script refuses a lock directory that isn't the user's or that others can write to. `LOCK_FILE` in the conf overrides the path.

## Considered options

- `lockf` on `run.lock` in the app directory, as before: `lockf` holds the lock on its own descriptor and doesn't pass it to the script, so the lock lasted only as long as `lockf`. Killing the script and `lockf` left osxphotos running unlocked, and the next run started a second export against the same export database and share. Rejected.
- A check before the export for a running `osxphotos export` with this conf's export database: needed only if uv closed inherited descriptors, which it doesn't. Rejected.
- A mode-0700 directory of our own under `/tmp`, also emptied at boot: the script would have to create it and check its owner and mode, because another user could make it first. The per-user temporary directory is already private. Rejected.
