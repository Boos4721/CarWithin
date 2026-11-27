#!/bin/bash
# Run the pure Swift BMS protocol and experience tests without UIKit, CoreBluetooth or CryptoKit.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
if ! command -v swift >/dev/null 2>&1; then
    echo 'Swift 5.9+ is required to run the BMS protocol tests.' >&2
    exit 127
fi
bms_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/carwithin-bms-tests.XXXXXX")"
trap 'rm -rf "$bms_test_dir"' EXIT
mkdir -p "$bms_test_dir/Sources/TDSCarKitCore" "$bms_test_dir/Tests/TDSCarKitCoreTests"
cp "$project_root/Sources/TDSCarKitCore/Localization.swift" "$bms_test_dir/Sources/TDSCarKitCore/"
cp "$project_root/Sources/TDSCarKitCore/ANTBMSRideRecords.swift" "$bms_test_dir/Sources/TDSCarKitCore/"
cp "$project_root/Tests/TDSCarKitCoreTests/ANTBMSRideRecordTests.swift" "$bms_test_dir/Tests/TDSCarKitCoreTests/"
for name in BMSFamily BMSFieldCapabilities BMSExperience BMSOverviewPresentation BMSReadOnlyProtocol BMSJBDJK BMSYanYang BMSOtherBoards BMSLuXing; do
    cp "$project_root/Sources/TDSCarKitCore/$name.swift" "$bms_test_dir/Sources/TDSCarKitCore/"
done
cp "$project_root/Tests/TDSCarKitCoreTests/BMSLuXingTests.swift" "$bms_test_dir/Tests/TDSCarKitCoreTests/"
cp "$project_root/Tests/TDSCarKitCoreTests/BMSOverviewPresentationTests.swift" "$bms_test_dir/Tests/TDSCarKitCoreTests/"
cp "$project_root/Tests/TDSCarKitCoreTests/BMSRecommendationTests.swift" "$bms_test_dir/Tests/TDSCarKitCoreTests/"
cp "$project_root/Tests/TDSCarKitCoreTests/BMSRecordingCoverageTests.swift" "$bms_test_dir/Tests/TDSCarKitCoreTests/"
cp "$project_root/Tests/TDSCarKitCoreTests/BMSExperienceTests.swift" "$bms_test_dir/Tests/TDSCarKitCoreTests/"
cp "$project_root/Tests/TDSCarKitCoreTests/MultibrandBMSTests.swift" "$bms_test_dir/Tests/TDSCarKitCoreTests/"
cp "$project_root/Sources/TDSCarKitCore/ANTBMSProtocol.swift" "$bms_test_dir/Sources/TDSCarKitCore/"
cp "$project_root/Sources/TDSCarKitCore/ANTBMSCardConfiguration.swift" "$bms_test_dir/Sources/TDSCarKitCore/"
cp "$project_root/Sources/TDSCarKitCore/ANTBMSSessionStatistics.swift" "$bms_test_dir/Sources/TDSCarKitCore/"
cp "$project_root/Tests/TDSCarKitCoreTests/ANTBMSProtocolTests.swift" "$bms_test_dir/Tests/TDSCarKitCoreTests/"
cp "$project_root/Tests/TDSCarKitCoreTests/ANTBMSCardConfigurationTests.swift" "$bms_test_dir/Tests/TDSCarKitCoreTests/"
cp "$project_root/Tests/TDSCarKitCoreTests/ANTBMSSessionStatisticsTests.swift" "$bms_test_dir/Tests/TDSCarKitCoreTests/"
cat > "$bms_test_dir/Package.swift" <<'PACKAGE'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "ANTBMSProtocolValidation", targets: [
    .target(name: "TDSCarKitCore"),
    .testTarget(name: "TDSCarKitCoreTests", dependencies: ["TDSCarKitCore"])
])
PACKAGE
swift test --disable-sandbox --package-path "$bms_test_dir"
