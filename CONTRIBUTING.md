# Contributing

Issues and pull requests are welcome, but I promise nothing. The tool works for its author. If it doesn't suit you, fork it.

There are no tagged releases yet. Only `main` is maintained.

`make test` must pass. It runs shellcheck, a jq check of the example dashboard, `tests/mirror-run.sh`, the preflight check tests and `tests/install.sh`. The tests never touch a real Photos library or share. They run the script with a test conf and stub commands on `PATH`, and check only the exit code, the outcome line, the stubs' recorded arguments and the files written. Never point a test at your real conf.

## For the maintainer

The default osxphotos source is a commit on `main` of the author's fork, [TimJDFletcher/osxphotos](https://github.com/TimJDFletcher/osxphotos), which mirrors upstream's `main`. It is unreleased upstream code past 0.77.2, and it reports its version as 0.77.2. Stock 0.77.2 downloads evicted RAW+JPEG pairs ([upstream PR #2265](https://github.com/RhetTbull/osxphotos/pull/2265)) and edited Live Photos ([#2266](https://github.com/RhetTbull/osxphotos/pull/2266)) from iCloud on every run, even when they are already on the share. In the author's library that was about 4,200 pairs, some 170 GB, per run. The pin goes back to PyPI once upstream releases the fixes, and then `renovate.json` needs a custom manager again, with the `pypi` datasource, so Renovate follows upstream's releases.

The pin is `default_osxphotos_source` in `osxphotos-nas-mirror.sh`. `tests/mirror-run.sh` checks it. To change the osxphotos version, sync the fork's `main` with upstream and put the new commit's full SHA in both files. Nothing bumps it automatically. Quote the SHA only in those two files, or a copy goes stale. A bump reaches launchd runs only once the app is rebuilt with `make app` and installed; merging it isn't enough.
