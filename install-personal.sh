#!/bin/bash
# Personal-fork install helper:
#   1. kill running AeroSpace
#   2. wipe /Applications/AeroSpace.app
#   3. copy fresh build there
#   4. strip macOS-injected xattrs (cp -r adds FinderInfo + fpfs metadata that
#      block launch on adhoc-signed bundles)
#   5. open the app
#
# Run after ./build-release-personal.sh.

set -e
cd "$(dirname "$0")"

if ! test -d .release/AeroSpace.app; then
    echo "No .release/AeroSpace.app — run ./build-release-personal.sh first." >&2
    exit 1
fi

pkill -x AeroSpace 2>/dev/null || true
sleep 1

rm -rf /Applications/AeroSpace.app
cp -r .release/AeroSpace.app /Applications/
xattr -rc /Applications/AeroSpace.app

open /Applications/AeroSpace.app
sleep 2

if pgrep -x AeroSpace > /dev/null; then
    echo "✅ AeroSpace running (pid $(pgrep -x AeroSpace))"
    echo "   If tiling stops working, re-grant Accessibility:"
    echo "   System Settings → Privacy & Security → Accessibility → AeroSpace"
else
    echo "❌ AeroSpace not running — check Console.app for errors"
    exit 1
fi
