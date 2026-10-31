# Run osxphotos through uvx from a pinned source, not Homebrew

From a checkout, osxphotos runs with `uvx --python 3.13`, from a pinned source. The app that launchd runs carries that same pin, built in (ADR 0007). Homebrew's formula broke when Homebrew's cffi dropped Python 3.13 (`No module named '_cffi_backend'`); uvx gives osxphotos its own Python 3.13 environment. A mirror also shouldn't upgrade its exporter between runs, so the version is pinned.

The default source is a commit on `main` of the author's fork of osxphotos, which mirrors upstream's `main`. osxphotos 0.77.2 downloads evicted RAW+JPEG pairs and edited Live Photos from iCloud again on every run. Upstream has merged the fixes (RhetTbull/osxphotos#2265 and #2266) but not released them, so the pin is unreleased code, as a full SHA that can't move. The pin goes back to PyPI once upstream releases the fixes. `OSXPHOTOS_SOURCE` in the conf overrides it.
