# The share is a mirror; the archive is built outside the tool

The export runs with `cleanup = true`, so deletions in the library are mirrored to the share. The share is an exact copy of the library as of the last good run.

The archive (the history of the mirror) is built outside this tool, for example with ZFS snapshots on the NAS (the author's setup) or restic. History and retention belong to tools made for them, and leaving them out keeps this tool simple.
