# Mount the share as Finder does, under /Volumes

The tool mounts the share with AppleScript's `mount volume`, as Finder does, so macOS puts it under `/Volumes`. It does not mount onto a mount point of its own. Under `/Volumes`, a share that drops leaves no folder behind to write into: macOS removes the mount point, and only root can make one there. A mount point we made would stay behind as an empty local folder, and osxphotos would write the mirror onto the Mac's disk.

`mount volume` also reads the login keychain as Finder does. A share already mounted from Finder is used where it is.
