#!/bin/bash
# Personal-fork release build.
# Skips upstream packaging steps that need extra toolchains:
#   - build-docs.sh    (Ruby + asciidoctor)
#   - build-shell-completion.sh (Rust/cargo + fish + bash 5)
#   - zip/manpage/brew-cask packaging
#
# Produces:
#   .release/AeroSpace.app   – installable bundle (sign-to-run-locally)
#   .release/aerospace       – CLI binary (universal arm64+x86_64)
#
# Usage: ./build-release-personal.sh [--build-version X.Y.Z]

cd "$(dirname "$0")"
source ./script/setup.sh

build_version="0.0.0-FORK"
codesign_identity="-"   # sign-to-run-locally; no Apple Developer account needed
while test $# -gt 0; do
    case $1 in
        --build-version) build_version="$2"; shift 2;;
        --codesign-identity) codesign_identity="$2"; shift 2;;
        *) echo "Unknown option $1" > /dev/stderr; exit 1 ;;
    esac
done

#############
### BUILD ###
#############

# Generate xcodeproj with our build version + codesign identity.
# We skip check-uncommitted-files.sh: upstream uses it to catch xcodegen-output drift,
# but in a personal fork the xcodeproj will always differ (directory name leaks into
# pbxproj package references) and that's fine — we revert the xcodeproj after
# the build (only the xcodeproj — narrower than upstream's `git checkout .`,
# which would also wipe any work-in-progress source edits).
./generate.sh --build-version "$build_version" --codesign-identity "$codesign_identity" --generate-git-hash --ignore-cmd-help --ignore-shell-parser

# CLI (universal binary)
swift build -c release --arch arm64 --arch x86_64 --product aerospace -Xswiftc -warnings-as-errors

rm -rf .release && mkdir .release

# Pre-strip xattrs on source files: macOS 15+ stamps every file with com.apple.provenance,
# which xcodebuild's auto-codesign refuses ("resource fork, Finder information, or similar
# detritus not allowed"). Strip what we own; SPM checkouts under .build are read-only and
# don't ship into the bundle so we ignore xattr errors there.
xattr -rc resources Sources docs/config-examples 2>/dev/null || true

xcode_configuration="Release"
xcodebuild -version

# Build without auto-codesign; we strip xattrs from the bundle and sign manually after.
xcodebuild-pretty .release/xcodebuild.log clean build \
    -scheme AeroSpace \
    -destination "generic/platform=macOS" \
    -configuration "$xcode_configuration" \
    -derivedDataPath .xcode-build \
    CODE_SIGNING_ALLOWED=NO

git checkout -- AeroSpace.xcodeproj

cp -r ".xcode-build/Build/Products/$xcode_configuration/AeroSpace.app" .release
cp -r .build/apple/Products/Release/aerospace .release

#####################
### SIGN APP+CLI  ###
#####################

# Strip provenance/finderinfo from bundle contents, then codesign with the entitlements file.
xattr -rc .release/AeroSpace.app
codesign --force --sign "$codesign_identity" \
    --entitlements resources/AeroSpace.entitlements \
    --timestamp=none --generate-entitlement-der \
    .release/AeroSpace.app

xattr -c .release/aerospace
codesign --force --sign "$codesign_identity" .release/aerospace

################
### VALIDATE ###
################

check-universal-binary() {
    if ! file "$1" | grep --fixed-string -q "Mach-O universal binary with 2 architectures: [x86_64:Mach-O 64-bit executable x86_64] [arm64"; then
        echo "$1 is not a universal binary"
        exit 1
    fi
}

check-universal-binary .release/AeroSpace.app/Contents/MacOS/AeroSpace
check-universal-binary .release/aerospace

codesign -v .release/AeroSpace.app
codesign -v .release/aerospace

echo
echo "✅ Personal-fork release build complete"
echo "   App:  .release/AeroSpace.app"
echo "   CLI:  .release/aerospace"
echo
echo "To install:"
echo "   pkill -x AeroSpace 2>/dev/null"
echo "   rm -rf /Applications/AeroSpace.app"
echo "   cp -r .release/AeroSpace.app /Applications/"
echo "   open /Applications/AeroSpace.app"
