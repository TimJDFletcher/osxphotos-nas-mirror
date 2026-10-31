# Contributing

Issues and pull requests are welcome, but I promise nothing. The tool works for its author. If it doesn't suit you, fork it.

There are no tagged releases yet. Only `main` is maintained.

`make test` must pass. It runs shellcheck, a jq check of the example dashboard, `tests/mirror-run.sh`, the preflight check tests and `tests/install.sh`. The tests never touch a real Photos library or share. They run the script with a test conf and stub commands on `PATH`, and check only the exit code, the outcome line, the stubs' recorded arguments and the files written. Never point a test at your real conf.

## For the maintainer

The default osxphotos source is a tag on the author's fork, [TimJDFletcher/osxphotos](https://github.com/TimJDFletcher/osxphotos) (branch `fixes-0.77.2`, see its [`FORK.md`](https://github.com/TimJDFletcher/osxphotos/blob/fixes-0.77.2/FORK.md)). The fork is osxphotos 0.77.2 plus two fixes. Stock 0.77.2 downloads evicted RAW+JPEG pairs ([upstream PR #2265](https://github.com/RhetTbull/osxphotos/pull/2265)) and edited Live Photos ([#2266](https://github.com/RhetTbull/osxphotos/pull/2266)) from iCloud on every run, even when they are already on the share. In the author's library that was about 4,200 pairs, some 170 GB, per run. The pin goes back to PyPI once upstream releases the fixes.

The pin is `default_osxphotos_source` in `osxphotos-nas-mirror.sh`. `tests/mirror-run.sh` checks it, and Renovate bumps both. To change the osxphotos version, push an annotated tag `vX.Y.Z-tim.N` to the fork. Renovate follows the fork's tags and reads only that scheme as a version, so it proposes the next `-tim.N` tag and never the upstream tags the fork also carries. Quote the tag only in those two files, or Renovate leaves the copy behind. A bump reaches launchd runs only once the app is rebuilt with `make app` and installed; merging it isn't enough.
