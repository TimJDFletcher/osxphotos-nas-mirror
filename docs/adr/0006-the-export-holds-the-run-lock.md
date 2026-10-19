# The export holds the run lock

One run at a time, and one export. The script takes an exclusive kernel lock (`flock`) on the lock file through a descriptor that the export (uv and osxphotos) inherits. The script's own sleeps and `bounded`'s watcher deliberately don't get it, so they can't hold the lock after the script has gone. A `flock` lock belongs to the open file, and every process that holds a descriptor for it keeps it, so the lock stays held while osxphotos runs, even if the script is killed. A run that can't take it at once ends `skipped-locked`. macOS has no `flock` command, so a short `perl` call takes the lock on the inherited descriptor. uv passes the descriptor on: `lsof` on the python that `uvx … osxphotos` starts shows it open.

A run stopped by SIGTERM, SIGINT or SIGHUP stops osxphotos as the share watchdog does and ends `interrupted`. SIGKILL can't be trapped, and the lock covers it.

The lock file is `run.lock` in the app directory. `LOCK_FILE` in the conf overrides it.

## Considered options

- `lockf` on `run.lock` in the app directory, as before: `lockf` holds the lock on its own descriptor and doesn't pass it to the script, so the lock lasted only as long as `lockf`. Killing the script and `lockf` left osxphotos running unlocked, and the next run started a second export against the same export database and share. Rejected.
- A check before the export for a running `osxphotos export` with this conf's export database: needed only if uv closed inherited descriptors, which it doesn't. Rejected.
- A lock file somewhere emptied at boot, as the issue's brief asked: the per-user temporary directory (`getconf DARWIN_USER_TEMP_DIR`) or a mode-0700 directory under `/tmp`. The point was that a reboot clears a broken lock. But a `flock` lock can't outlive its holders, and a reboot ends them all, so a reboot clears it wherever the file is, and a leftover file never blocks a run. Both places also have a daily cleaner (dirhelper) that deletes files a few days old. It could delete a long export's lock file, and the next run would then lock a new file and start a second export. Rejected.

## How the overlap happened

The second export most likely came from a run started by hand. Under launchd it shouldn't happen: "When a job dies, launchd kills any remaining processes with the same process group ID as the job", unless the job sets `AbandonProcessGroup` (`launchd.plist(5)`), and ours doesn't. That is launchd's documented behaviour; it wasn't verified here.
