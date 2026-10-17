# Keep the export database on the Mac's SSD

The export database lives in the app directory on the Mac's SSD (`--exportdb`), not on the share. osxphotos reads and writes it constantly, and that is much faster locally than over SMB. The tool copies it to the share only after a good run, because a copy taken after a failed or partial run would not match what is on the share.

## Considered options

- `--ramdb`: faster still, but the state is lost if a run is interrupted. Rejected.
