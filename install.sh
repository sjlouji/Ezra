#!/bin/bash
# Installs the latest Ezra for Mac into Applications and opens it.
#
#   curl -fsSL https://raw.githubusercontent.com/sjlouji/Ezra/main/install.sh | bash
#
# The download is not notarized by Apple. Fetched this way it opens without the "Apple could not verify" warning,
# because macOS shows that warning only for files a browser downloaded.
#
# EZRA_INSTALL_DIR  the folder to install into (default: /Applications, or ~/Applications when that cannot be written)
# EZRA_NO_OPEN=1    install without opening Ezra
# EZRA_REPLACE=1    replace an installed Ezra that has sync set up (the download has no sync settings)

set -euo pipefail

URL="https://github.com/sjlouji/Ezra/releases/latest/download/Ezra-mac.zip"
NEEDS=26

fail() {
    echo "Ezra was not installed: $1" >&2
    exit 1
}

[ "$(uname -s)" = "Darwin" ] || fail "this is the Mac app, and this is not a Mac."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge "$NEEDS" ] || fail "Ezra needs macOS $NEEDS or later; this Mac has $(sw_vers -productVersion)."

dir="${EZRA_INSTALL_DIR:-/Applications}"
if [ -z "${EZRA_INSTALL_DIR:-}" ] && [ ! -w "$dir" ]; then
    dir="$HOME/Applications"
fi
mkdir -p "$dir" || fail "the folder $dir could not be made."
[ -w "$dir" ] || fail "the folder $dir cannot be written to."
app="$dir/Ezra.app"

if [ -e "$app/Contents/Resources/GoogleService-Info.plist" ] && [ "${EZRA_REPLACE:-}" != "1" ]; then
    fail "the Ezra in $dir has sync set up, and the download has none, so it was left as it is. Run again with EZRA_REPLACE=1 to replace it anyway."
fi
if pgrep -qf "$app/Contents/MacOS/Ezra"; then
    fail "Ezra is open. Quit it and run this again."
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "Downloading Ezra…"
curl -fL --progress-bar "$URL" -o "$work/Ezra.zip" || fail "the download failed. Check the connection and try again."
ditto -x -k "$work/Ezra.zip" "$work/unpacked" || fail "the download could not be unpacked."
[ -d "$work/unpacked/Ezra.app" ] || fail "the download did not contain Ezra."
# The app must be whole: every file as it was when it was built.
codesign --verify --deep --strict "$work/unpacked/Ezra.app" || fail "the downloaded app is damaged."

if [ -e "$app" ]; then
    rm -rf "$app" || fail "the Ezra already in $dir could not be replaced."
fi
ditto "$work/unpacked/Ezra.app" "$app" || fail "Ezra could not be copied into $dir."

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist" 2>/dev/null || echo "")
echo "Ezra $version is installed in $dir."
if [ "${EZRA_NO_OPEN:-}" != "1" ]; then
    open "$app"
fi
