#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
stage="$(mktemp -d)"
trap 'rm -rf -- "$stage"' EXIT
extra_sources=()
if [[ "$(uname -s)" == Darwin ]]; then
    # The Darwin network implementation shares the production socket and error types.
    extra_sources+=("$root/App/TailingSocket.swift" "$root/App/TailingProtocol.swift" "$root/App/TailingDisplayProfile.swift")
fi
"${SWIFTC:-swiftc}" -swift-version 5 "$root/Sources/TDSCarKitCore/Localization.swift" "$root/App/TailingDiscovery.swift" \
    "${extra_sources[@]}" "$root/Tools/TailingDiscoverySmoke.swift" -o "$stage/discovery-test"
"$stage/discovery-test"
