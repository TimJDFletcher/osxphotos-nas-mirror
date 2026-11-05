# Run osxphotos through uvx from a pinned source, not Homebrew

From a checkout, osxphotos runs with `uvx --python 3.13`, from a pinned source. The app that launchd runs carries that same pin, built in (ADR 0007). Homebrew's formula broke when Homebrew's cffi dropped Python 3.13 (`No module named '_cffi_backend'`); uvx gives osxphotos its own Python 3.13 environment. A mirror also shouldn't upgrade its exporter between runs, so the version is pinned.

The default source is a PyPI release, `osxphotos==X.Y.Z`, which Renovate proposes bumps for. It must be 0.78.0 or later: 0.77.2 and earlier download evicted RAW+JPEG pairs and edited Live Photos from iCloud again on every run. The fixes (RhetTbull/osxphotos#2265 and #2266) came from this project, and until 0.78.0 released them the pin was a commit of the author's fork. `OSXPHOTOS_SOURCE` in the conf overrides it.
