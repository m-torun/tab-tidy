#!/bin/bash
# Builds "Tab Tidy.app" into build/.
#
#   ./build.sh            build only
#   ./build.sh install    build, copy to ~/Applications (or $INSTALL_DIR) and start it
#
# The app is signed ad hoc unless SIGN_IDENTITY names a code signing identity.
# With ad hoc signing macOS asks again for permission to control Chrome after
# each rebuild.
set -euo pipefail

cd "$(dirname "$0")"
name="Tab Tidy"
app="build/$name.app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Info.plist "$app/Contents/"
cp -R Resources/ "$app/Contents/Resources/"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" \
    -o "$app/Contents/MacOS/TabTidy" Sources/*.swift
codesign --force --sign "${SIGN_IDENTITY:--}" "$app"
echo "Built $app"

if [[ "${1:-}" == "install" ]]; then
    dest="${INSTALL_DIR:-$HOME/Applications}"
    mkdir -p "$dest"
    if pkill -x TabTidy; then
        while pgrep -x TabTidy >/dev/null; do sleep 0.2; done
    fi
    rm -rf "${dest:?}/$name.app"
    cp -R "$app" "$dest/"
    open "$dest/$name.app"
    echo "Installed and started $dest/$name.app"
fi
