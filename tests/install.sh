#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# tests/install.sh -- tests for make install. It runs against a temporary HOME,
# never the real one, and does not run launchctl.

set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
label=io.github.timjdfletcher.osxphotos-nas-mirror
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failed=0

check() { # check ACTUAL EXPECTED DESCRIPTION
    if [ "$1" = "$2" ]; then
        echo "ok: $3"
    else
        echo "FAIL: $3 (expected '$2', got '$1')"
        failed=1
    fi
}

home="$tmp/home with space"
out=$(make -C "$root" install HOME="$home")
plist=$home/Library/LaunchAgents/$label.plist

check "$([ -f "$plist" ] && echo yes)" yes "install creates LaunchAgents and the plist"
check "$(grep -c "<string>$root/osxphotos-nas-mirror.sh</string>" "$plist")" 1 \
    "the plist has the checkout path"
check "$(grep -c "<string>$home/Library/Application Support/osxphotos-nas-mirror/osxphotos-nas-mirror.log</string>" "$plist")" 1 \
    "the plist has the temporary HOME"
check "$(grep -c '@[A-Z]*@' "$plist" || true)" 0 "no placeholder is left"
check "$(plutil -lint "$plist" > /dev/null && echo yes)" yes "the plist passes plutil -lint"
check "$(printf '%s\n' "$out" | grep -c "launchctl load")" 1 "install prints the launchctl load command"

# A HOME with characters that are special to sed (& | \) and to XML (& < >).
odd="$tmp/odd & pipe | angle <x> back\\slash"
make -C "$root" install HOME="$odd" > /dev/null
plist=$odd/Library/LaunchAgents/$label.plist
xml_odd="$tmp/odd &amp; pipe | angle &lt;x&gt; back\\slash"
check "$(grep -c -F "<string>$xml_odd/Library/Application Support/osxphotos-nas-mirror/osxphotos-nas-mirror.log</string>" "$plist")" 1 \
    "a HOME with & | < > and a backslash is written escaped"
check "$(grep -c '@[A-Z]*@' "$plist" || true)" 0 "no placeholder is left with an odd HOME"
check "$(plutil -lint "$plist" > /dev/null && echo yes)" yes "the plist for an odd HOME passes plutil -lint"

exit "$failed"
