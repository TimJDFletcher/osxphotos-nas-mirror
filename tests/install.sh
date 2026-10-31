#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# tests/install.sh -- tests for make install and the app's runner. It runs
# against a temporary HOME, never the real one, with a stand-in for the app
# (make app is slow and needs the signing key), and does not run launchctl.

set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
label=io.github.timjdfletcher.osxphotos-nas-mirror
tmp=$(cd "$(mktemp -d)" && pwd -P)
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

# The stand-in: the real runner, with a script that shows what it was given.
app="$tmp/stand-in.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
clang -O2 -o "$app/Contents/MacOS/osxphotos-nas-mirror" "$root/launchd/runner.c"
script=$app/Contents/Resources/osxphotos-nas-mirror.sh
cat > "$script" <<'SCRIPT'
#!/bin/sh
trap 'exit 9' TERM
case ${1:-} in
    stop) touch "$2"; while :; do sleep 0.1; done ;;
esac
echo "$0 $*"
exit 7
SCRIPT
chmod +x "$script"
runner=$app/Contents/MacOS/osxphotos-nas-mirror

rc=0; printed=$("$runner" --force) || rc=$?
check "$rc" 7 "the runner exits with the script's code"
check "$printed" "$(dirname "$runner")/../Resources/osxphotos-nas-mirror.sh --force" \
    "the runner runs the script in the app's Resources, with its arguments"
"$runner" stop "$tmp/started" &
pid=$!
while [ ! -e "$tmp/started" ]; do sleep 0.1; done
kill -TERM "$pid"
rc=0; wait "$pid" || rc=$?
check "$rc" 9 "the runner forwards SIGTERM to the script"
mv "$script" "$tmp/moved"
rc=0; "$runner" 2> /dev/null || rc=$?
check "$rc" 70 "the runner fails if the script is missing"
mv "$tmp/moved" "$script"

rc=0; make -C "$root" install HOME="$tmp/nothing" APP="$tmp/missing.app" > /dev/null 2>&1 || rc=$?
check "$([ "$rc" -ne 0 ] && echo yes)" yes "install stops if the app isn't built"

home="$tmp/home with space"
out=$(make -C "$root" install HOME="$home" APP="$app")
plist=$home/Library/LaunchAgents/$label.plist

check "$([ -f "$plist" ] && echo yes)" yes "install creates LaunchAgents and the plist"
check "$(grep -c "<string>$home/Applications/osxphotos-nas-mirror.app/Contents/MacOS/osxphotos-nas-mirror</string>" "$plist")" 1 \
    "the plist starts the app in ~/Applications"
check "$([ -x "$home/Applications/osxphotos-nas-mirror.app/Contents/MacOS/osxphotos-nas-mirror" ] && echo yes)" yes \
    "install copies the app to ~/Applications"
check "$(grep -c "<string>$home/Library/Application Support/osxphotos-nas-mirror/osxphotos-nas-mirror.log</string>" "$plist")" 1 \
    "the plist has the temporary HOME"
check "$(grep -c '@[A-Z]*@' "$plist" || true)" 0 "no placeholder is left"
check "$(plutil -lint "$plist" > /dev/null && echo yes)" yes "the plist passes plutil -lint"
check "$(printf '%s\n' "$out" | grep -c "launchctl load")" 1 "install prints the launchctl load command"

# A HOME with characters that are special to sed (& | \) and to XML (& < >).
odd="$tmp/odd & pipe | angle <x> back\\slash"
make -C "$root" install HOME="$odd" APP="$app" > /dev/null
plist=$odd/Library/LaunchAgents/$label.plist
xml_odd="$tmp/odd &amp; pipe | angle &lt;x&gt; back\\slash"
check "$(grep -c -F "<string>$xml_odd/Library/Application Support/osxphotos-nas-mirror/osxphotos-nas-mirror.log</string>" "$plist")" 1 \
    "a HOME with & | < > and a backslash is written escaped"
check "$(grep -c '@[A-Z]*@' "$plist" || true)" 0 "no placeholder is left with an odd HOME"
check "$(plutil -lint "$plist" > /dev/null && echo yes)" yes "the plist for an odd HOME passes plutil -lint"

exit "$failed"
