#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# launchd/build-app.sh OUTPUT.app -- build the self-contained app: the script,
# its config and preflight checks, a private Python with osxphotos, and the
# runner, signed with SIGN_IDENTITY (ADR 0007). uv is needed here, not at run
# time. The osxphotos pin is read from the script, the one place it is kept.

set -eu

app=$1
root=$(cd "$(dirname "$0")/.." && pwd -P)
label=io.github.timjdfletcher.osxphotos-nas-mirror
identity=${SIGN_IDENTITY:-osxphotos-nas-mirror local signing}
source=$(sed -n 's/^default_osxphotos_source=//p' "$root/osxphotos-nas-mirror.sh")
[ -n "$source" ] || { echo "no default_osxphotos_source in the script" >&2; exit 1; }

rm -rf "$app"
macos=$app/Contents/MacOS
resources=$app/Contents/Resources
mkdir -p "$macos" "$resources"

cp "$root/launchd/Info.plist" "$app/Contents/Info.plist"
clang -O2 -o "$macos/osxphotos-nas-mirror" "$root/launchd/runner.c"
cp "$root/osxphotos-nas-mirror.sh" "$root/osxphotos.toml" "$resources/"
cp -R "$root/preflight-checks" "$resources/preflight-checks"

python_home=$(mktemp -d)
iconset=$(mktemp -d)/icon.iconset
trap 'rm -rf "$python_home" "$(dirname "$iconset")"' EXIT
mkdir "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$root/launchd/icon.png" --out "$iconset/icon_${size}x${size}.png" > /dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$root/launchd/icon.png" --out "$iconset/icon_${size}x${size}@2x.png" > /dev/null
done
iconutil -c icns -o "$resources/icon.icns" "$iconset"

UV_PYTHON_INSTALL_DIR=$python_home uv python install --quiet 3.13
# -type d: uv also leaves a symlink beside it.
cp -R "$(find "$python_home" -maxdepth 1 -type d -name 'cpython-3.13*')" "$resources/python"
python=$resources/python/bin/python3.13
uv pip install --quiet --python "$python" --break-system-packages "$source"
# A run must not write .pyc files: they would break the signature's seal. The
# script runs Python with -B, and these make that free.
"$python" -m compileall -q "$resources/python/lib" > /dev/null || true

# Inside out: everything the loader loads, then the app, which seals the rest.
find "$resources/python" -type f | while IFS= read -r file; do
    if file -b "$file" | grep -q 'Mach-O'; then
        codesign --force --sign "$identity" "$file" 2> /dev/null
    fi
done
codesign --force --sign "$identity" --identifier "$label" "$app"
# Signed, it must still run, and running it must not touch the seal.
"$python" -B -m osxphotos version
codesign --verify --strict "$app"
