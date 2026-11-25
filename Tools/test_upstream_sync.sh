#!/usr/bin/env bash
# Native macOS checks for upstream features merged into the development branch; no simulator.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
upstream_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/carwithin-upstream-sync.XXXXXX")"
trap 'rm -rf "$upstream_test_dir"' EXIT
cd "$project_root"
bash Tools/test_wifi_credentials.sh
bash Tools/test_carlife_discovery.sh
bash Tools/test_airplay_hls.sh
swiftc -swift-version 5 Sources/TDSCarKitCore/Localization.swift App/SupporterDirectory.swift \
    Tools/SupporterDirectorySmoke.swift -o "$upstream_test_dir/supporter-test"
"$upstream_test_dir/supporter-test"
swiftc -swift-version 5 Sources/TDSCarKitCore/Localization.swift App/AppReleaseService.swift \
    Tools/UpdateSmoke.swift -o "$upstream_test_dir/update-test"
"$upstream_test_dir/update-test"
localization_app="$upstream_test_dir/LocalizationSmoke.app"
mkdir -p "$localization_app/Contents/MacOS" "$localization_app/Contents/Resources"
swiftc -swift-version 5 Sources/TDSCarKitCore/Localization.swift App/BrowserReceiverPage.swift \
    Tools/LocalizationSmoke.swift -o "$localization_app/Contents/MacOS/LocalizationSmoke"
python3 - "$project_root" "$localization_app" <<'PY'
import json, plistlib, sys
from pathlib import Path
root, app = map(Path, sys.argv[1:])
resources = app / 'Contents/Resources'
plist = {'CFBundleExecutable': 'LocalizationSmoke', 'CFBundleIdentifier': 'local.carwithin.localization-smoke',
         'CFBundleName': 'LocalizationSmoke', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
         'CFBundleDevelopmentRegion': 'zh-Hans', 'CFBundleLocalizations': ['en', 'zh-Hans']}
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(plist))
catalog = json.loads((root / 'App/Localization/Localizable.xcstrings').read_text())
for language in ['en', 'zh-Hans']:
    folder = resources / (language + '.lproj'); folder.mkdir()
    values = []
    for key, entry in catalog['strings'].items():
        value = entry.get('localizations', {}).get(language, {}).get('stringUnit', {}).get('value', key)
        values.append(json.dumps(key, ensure_ascii=False) + ' = ' + json.dumps(value, ensure_ascii=False) + ';')
    (folder / 'Localizable.strings').write_text('\n'.join(values) + '\n')
(resources / 'Receiver.en.html').write_bytes((root / 'App/Localization/Receiver.en.html').read_bytes())
PY
"$localization_app/Contents/MacOS/LocalizationSmoke" -AppleLanguages '(en)' --expect-english
"$localization_app/Contents/MacOS/LocalizationSmoke" -AppleLanguages '(zh-Hans)'
"$localization_app/Contents/MacOS/LocalizationSmoke" -AppleLanguages '(fr)'
