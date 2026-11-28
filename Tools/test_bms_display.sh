#!/usr/bin/env bash
# Production CoreText/CoreGraphics bitmap rendering and Core Image placement on native macOS.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
display_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/carwithin-bms-display.XXXXXX")"
trap 'rm -rf "$display_test_dir"' EXIT
swiftc -swift-version 5 \
    "$project_root/Sources/TDSCarKitCore/Localization.swift" \
    "$project_root/Sources/TDSCarKitCore/BMSFamily.swift" \
    "$project_root/Sources/TDSCarKitCore/ANTBMSProtocol.swift" \
    "$project_root/Sources/TDSCarKitCore/ANTBMSCardConfiguration.swift" \
    "$project_root/App/BMSCardRenderer.swift" "$project_root/App/InstrumentVideoCanvas.swift" \
    "$project_root/Tools/BMSCardDisplaySmoke.swift" \
    -framework CoreText -framework CoreGraphics -framework CoreImage -framework CoreVideo -framework ImageIO \
    -o "$display_test_dir/display-tests"
"$display_test_dir/display-tests" "${1:-$display_test_dir/previews}"
