# launchd runs a self-contained app

Started directly by launchd, the script is `/bin/bash`, and macOS refuses it the Photos library and network volumes without asking, so `cp` of the export database fails with `Operation not permitted`. Adding `/bin/bash` to Full Disk Access would work, but gives that access to anything run as a bash script.

So launchd starts an app, and the app runs the script as its child. macOS holds the app responsible for its descendants and asks for the specific permissions by the app's name, once. Tested on macOS 27.2 with one launchd job: plain `/bin/bash` was refused, and bash, `cp` and Python under the app were allowed after the prompt. The app stays a child rather than exec'ing, because an exec would turn it into `/bin/bash`.

The app carries everything: the script, `osxphotos.toml`, the preflight checks, and a private Python with osxphotos. A run doesn't need uv, Homebrew or the network to start, and an update is a new package. The app runs only the script inside it, so nothing else can borrow its permissions by passing a path. It holds Apple Silicon binaries only.

It is signed with a self-signed certificate, not ad hoc. An ad hoc identity is the hash of the code, so every package would lose the grants and the next run would wait for someone at the Mac. A grant to a certificate-signed app follows the certificate: tested by changing the code and signing again, with no new prompt. A Developer ID would do the same and allow notarization, but costs a yearly membership, and only the author installs this. Losing the key means allowing the prompts once more, so it isn't backed up. Other people build with their own `SIGN_IDENTITY`.

Python runs with `-B`, because a `.pyc` written into the bundle would break the signature's seal.

Under the app, macOS shows `ifconfig` every MAC address as `02:00:00:00:00:00`, so the dock check uses `networksetup`, which shows the real one. Plain bash under launchd saw the real address, so this only appeared in the app.

A checkout still runs by hand through uvx, which is what the tests stub and where the pin lives. `make app` reads the pin from the script.

These prompts don't conflict with ADR 0005: they come from macOS, once per certificate, and that ADR rules out a password dialog that could come on any run.
