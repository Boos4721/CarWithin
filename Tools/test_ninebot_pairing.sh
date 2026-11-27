#!/usr/bin/env bash
# Exercise the production Swift state machine on macOS using an in-memory BLE transport.
# This is not an iOS simulator or a physical Bluetooth/Keychain/crypto test.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
pairing_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/carwithin-pairing-tests.XXXXXX")"
trap 'rm -rf "$pairing_test_dir"' EXIT
python3 - "$project_root" "$pairing_test_dir/PairingLifecycle.swift" <<'PY'
from pathlib import Path
import sys
root, output = map(Path, sys.argv[1:])
client = (root / 'App/NinebotVehicleConnection.swift').read_text()
client = client.replace('import CoreBluetooth\n', '')
output.write_text((root / 'Tools/Fixtures/NinebotPairingTransport.swift').read_text() + '\n' + client + '\n' +
                  (root / 'Tools/NinebotPairingLifecycleSmoke.swift').read_text())
PY
swiftc -swift-version 5 -parse-as-library \
  "$project_root/Sources/TDSCarKitCore/Localization.swift" \
  "$project_root/Sources/TDSCarKitCore/Advertisement.swift" \
  "$project_root/Sources/TDSCarKitCore/DiscoveryEvidence.swift" \
  "$project_root/Sources/TDSCarKitCore/VehicleBLEFrame.swift" \
  "$project_root/Sources/TDSCarKitCore/VehicleAuthenticationAttempts.swift" \
  "$project_root/Sources/TDSCarKitCore/VehicleNavigationPolicy.swift" \
  "$project_root/Sources/TDSCarKitCore/NinebotVehicleSelection.swift" \
  "$project_root/Sources/TDSCarKitCore/NinebotPairingExperience.swift" \
  "$project_root/Sources/TDSCarKitCore/NinebotVehicleFinder.swift" \
  "$project_root/Sources/TDSCarKitCore/NinebotScanDiagnostics.swift" \
  "$project_root/Sources/TDSCarKitCore/VehiclePairingReadiness.swift" \
  "$pairing_test_dir/PairingLifecycle.swift" -o "$pairing_test_dir/pairing-test"
"$pairing_test_dir/pairing-test"
