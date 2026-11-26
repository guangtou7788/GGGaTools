#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This build requires macOS with Xcode and the iPhoneOS SDK. Use GitHub Actions." >&2
  exit 1
fi
SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
VERSION=0.3.3
LIBRARY="GGGaTools-${VERSION}.dylib"
OUTPUT="build/$LIBRARY"
mkdir -p build
xcrun --sdk iphoneos clang \
  -isysroot "$SDK_PATH" -arch arm64 -miphoneos-version-min=13.0 \
  -dynamiclib -fobjc-arc -fblocks -O2 -Wall -Wextra \
  -Wno-unused-parameter -Wno-deprecated-declarations \
  -framework Foundation -framework UIKit -framework QuartzCore -framework CoreGraphics \
  "-Wl,-install_name,@rpath/$LIBRARY" \
  -Wl,-compatibility_version,1.0 "-Wl,-current_version,$VERSION" \
  GGGaTools.m -o "$OUTPUT"
# Ad-hoc signature for the artifact. ESign must sign it again with the target IPA.
codesign --force --sign - "$OUTPUT"
codesign --verify --verbose "$OUTPUT"
file "$OUTPUT" | tee build/build-info.txt
xcrun lipo -info "$OUTPUT" | tee -a build/build-info.txt
xcrun otool -L "$OUTPUT" | tee -a build/build-info.txt
(cd build && shasum -a 256 "$LIBRARY" > SHA256SUMS.txt)
cp INSTALL.txt build/INSTALL.txt
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'version=%s\nlibrary=%s\n' "$VERSION" "$OUTPUT" >> "$GITHUB_OUTPUT"
fi
echo "Ready: $OUTPUT"
