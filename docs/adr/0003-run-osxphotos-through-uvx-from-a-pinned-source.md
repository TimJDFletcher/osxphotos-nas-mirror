# Run osxphotos through uvx from a pinned source, not Homebrew

osxphotos runs with `uvx --python 3.13`, from a pinned source. Homebrew's formula broke when Homebrew's cffi dropped Python 3.13 (`No module named '_cffi_backend'`); uvx gives osxphotos its own Python 3.13 environment. A mirror also shouldn't upgrade its exporter between runs, so the version is pinned.

The default source is a tag on the author's fork of osxphotos. It fixes two osxphotos 0.77.2 bugs that download evicted RAW+JPEG pairs and edited Live Photos from iCloud again on every run (upstream PRs RhetTbull/osxphotos#2265 and #2266). The pin goes back to PyPI once upstream releases the fixes. `OSXPHOTOS_SOURCE` in the conf overrides it, and Renovate bumps the fork tag.
