#!/bin/bash
# Deploy the personal fork to the MacBook Pro: rsync the repo over SSH,
# rebuild there, install, and verify the agent came back up.
#
# Run from the Mac mini (the dev machine). The MacBook has no GitHub
# credentials, so rsync from here is the transport — see machines.md.
#
# Usage:  ./deploy-macbook.sh [--build-only]
#   --build-only   rsync + remote build, but skip the install/restart step
#                  (useful when someone is actively working on the MacBook).

set -e
cd "$(dirname "$0")"

HOST="honzavilimec@192.168.1.140"
REMOTE_DIR="Projects/aerospace"

echo "→ rsync repo to $HOST:$REMOTE_DIR"
rsync -a --delete \
    --exclude '.release' --exclude '.xcode-build' \
    --exclude '.build' --exclude '.build-lane*' \
    ./ "$HOST:$REMOTE_DIR/"

if [ "$1" = "--build-only" ]; then
    echo "→ remote build (no install)"
    ssh -o BatchMode=yes "$HOST" "cd $REMOTE_DIR && git log --oneline -1 && ./build-release-personal.sh" | tail -4
    echo "✅ build-only done — run without --build-only to install"
    exit 0
fi

echo "→ remote rebuild + install (kills and restarts AeroSpace there)"
ssh -o BatchMode=yes "$HOST" "cd $REMOTE_DIR && git log --oneline -1 && ./rebuild-and-install.sh" | tail -4

# rebuild-and-install.sh already waits up to 8 s for the agent, but the
# freshly swapped binary occasionally dies once right after first launch
# (LaunchServices/Gatekeeper re-evaluation race) — observed 2026-06-12.
# Give it a few seconds and relaunch once if needed.
sleep 5
if ! ssh -o BatchMode=yes "$HOST" 'pgrep -x AeroSpace >/dev/null'; then
    echo "⚠️  AeroSpace died after first launch (known race) — relaunching once"
    ssh -o BatchMode=yes "$HOST" 'open /Applications/AeroSpace.app'
    sleep 5
fi

if ssh -o BatchMode=yes "$HOST" 'pgrep -x AeroSpace >/dev/null'; then
    ver=$(ssh -o BatchMode=yes "$HOST" "$REMOTE_DIR/.release/aerospace --version 2>/dev/null || true")
    echo "✅ AeroSpace running on MacBook${ver:+ ($ver)}"
else
    echo "❌ AeroSpace not running on the MacBook — check Console.app there" >&2
    exit 1
fi
