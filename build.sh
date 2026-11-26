#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This build requires macOS with Xcode and the iPhoneOS SDK. Use GitHub Actions." >&2
  exit 1
fi
SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
mkdir -p build
xcrun --sdk iphoneos clang \
  -isysroot "$SDK_PATH" -arch arm64 -miphoneos-version-min=13.0 \
  -dynamiclib -fobjc-arc -fblocks -O2 -Wall -Wextra \
  -Wno-unused-parameter -Wno-deprecated-declarations \
  -framework Foundation -framework UIKit -framework QuartzCore -framework CoreGraphics \
  -Wl,-install_name,@rpath/GGGaTools.dylib \
  -Wl,-compatibility_version,1.0 -Wl,-current_version,0.3.1 \
  GGGaTools.m -o build/GGGaTools.dylib
# Ad-hoc signature for the artifact. ESign must sign it again with the target IPA.
codesign --force --sign - build/GGGaTools.dylib
codesign --verify --verbose build/GGGaTools.dylib
file build/GGGaTools.dylib | tee build/build-info.txt
xcrun lipo -info build/GGGaTools.dylib | tee -a build/build-info.txt
xcrun otool -L build/GGGaTools.dylib | tee -a build/build-info.txt
shasum -a 256 build/GGGaTools.dylib > build/SHA256SUMS.txt
cp INSTALL.txt build/INSTALL.txt
echo "Ready: build/GGGaTools.dylib"
