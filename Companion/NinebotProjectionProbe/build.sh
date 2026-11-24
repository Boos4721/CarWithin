#!/bin/bash
set -euo pipefail
probe_root="$(cd "$(dirname "$0")" && pwd)"
probe_output="${1:-$probe_root/../../build/ninebot-probe}"
mkdir -p "$probe_output"
probe_sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$probe_sdk" \
  -miphoneos-version-min=16.0 -fobjc-arc -fblocks -Wall -Wextra -Werror \
  -Wno-unused-parameter -dynamiclib -O2 \
  -framework UIKit -framework Foundation -framework CoreVideo -framework CoreGraphics \
  -install_name @executable_path/Frameworks/CarWithinNinebotProbe.dylib \
  "$probe_root/ProjectionProbe.m" -o "$probe_output/CarWithinNinebotProbe.dylib"
file "$probe_output/CarWithinNinebotProbe.dylib"
otool -D "$probe_output/CarWithinNinebotProbe.dylib"
