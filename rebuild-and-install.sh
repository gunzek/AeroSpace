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
# Prefer the stable self-signed identity when this machine has it: ad-hoc
# signing ("-") yields a new CDHash every build, which invalidates the TCC
# Accessibility grant on every install (the app then shows the permission
# prompt and exits 0). A certificate identity keeps the designated
# requirement stable, so the grant survives rebuilds. Setup: see
# "Code signing" in machines.md / deploy-macbook.sh history (2026-06-12).
identity_args=()
if security find-identity -v -p codesigning 2>/dev/null | grep -q aerospace-dev; then
    echo "  (signing with aerospace-dev identity)"
    identity_args=(--codesign-identity aerospace-dev)
fi
./build-release-personal.sh "${identity_args[@]}"
build_exit=$?
if [ $build_exit -ne 0 ]; then
    echo "❌ release build failed (exit $build_exit)"
    exit $build_exit
fi

echo "→ installing"
./install-personal.sh
