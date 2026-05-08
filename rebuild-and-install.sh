#!/bin/bash
# Personal-fork "one-shot" rebuild + install: kills any straggling
# build/xcodebuild instances, force-wipes .release and .xcode-build
# directories, runs build-release-personal.sh, then install-personal.sh.
# Use this when the iterative build loop got tangled (multiple xcodebuild
# instances racing on .release/xcodebuild.log, leftover read-only files in
# .xcode-build, etc.).
#
# Usage:  ./rebuild-and-install.sh

set -e
cd "$(dirname "$0")"

echo "→ killing any in-flight build processes"
pkill -9 -f "build-release-personal\|build-debug\|xcodebuild\|swift-build" 2>/dev/null || true
sleep 2

echo "→ wiping .release and .xcode-build"
chmod -R u+w .release .xcode-build 2>/dev/null || true
rm -rf .release .xcode-build

echo "→ starting release build (this takes ~30–60 s)"
./build-release-personal.sh
build_exit=$?
if [ $build_exit -ne 0 ]; then
    echo "❌ release build failed (exit $build_exit)"
    exit $build_exit
fi

echo "→ installing"
./install-personal.sh
