# osxphotos-nas-mirror

Mirrors a Mac's Photos library to an SMB share on a NAS, using osxphotos.

## Language

**Run**:
One invocation of the tool, from start to its outcome.
_Avoid_: Job, sync

**Outcome**:
The single named result every run ends with, one of a fixed set, each with its own exit code.
_Avoid_: Status, result code

**Preflight check**:
A user-supplied check that decides, before anything is mounted, whether a run goes ahead. There can be several: they run in order, and the first that does not pass decides.
_Avoid_: Pre-check, location check, guard

**Dock check**:
One of the example preflight checks: the run goes ahead only when a given Ethernet dock is connected.
_Avoid_: Location check

**Share**:
The SMB share on the NAS that the library is exported to.
_Avoid_: Volume, mount, destination

**Mirror**:
What the share holds: the library as of the last good run, deletions included.
_Avoid_: Archive, backup copy

**Archive**:
The history of the mirror, built outside this tool, for example with ZFS snapshots or restic.
_Avoid_: Mirror, snapshot (for the share itself)

**Export database**:
osxphotos's record of what it has exported, kept on the Mac and copied to the share after a good run.
_Avoid_: State file, DB
