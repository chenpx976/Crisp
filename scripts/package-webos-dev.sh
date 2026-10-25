#!/bin/bash
# Package an already compiled Crisp-bin without replacing the installed app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP="$ROOT/build/Crisp LG.app"
test -f Crisp-bin
test -d /Applications/Crisp.app
mkdir -p build/localizations
ditto /Applications/Crisp.app "$APP"
cp Crisp-bin "$APP/Contents/MacOS/Crisp"
python3 - "$APP/Contents/Info.plist" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, 'rb') as stream:
    info = plistlib.load(stream)
info.update({
    'CFBundleIdentifier': 'com.crisp.webos-dev',
    'CFBundleName': 'Crisp LG',
    'CFBundleDisplayName': 'Crisp LG',
    'CFBundleShortVersionString': '1.7.1-webos-dev',
    'NSLocalNetworkUsageDescription': 'Connect to your LG TV to control speaker volume.',
    'SUEnableAutomaticChecks': False,
    'SUAutomaticallyUpdate': False,
})
info.setdefault('NSAppTransportSecurity', {})['NSAllowsLocalNetworking'] = True
with open(path, 'wb') as stream:
    plistlib.dump(info, stream)
PY
xcrun xcstringstool compile Crisp/Resources/Localizable.xcstrings --output-directory build/localizations
ditto build/localizations "$APP/Contents/Resources"
codesign --force --deep --sign - "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - "$APP/Contents/MacOS/crispctl"
codesign --force --sign - --entitlements Crisp/Crisp.entitlements "$APP"
codesign --verify --deep --strict "$APP"
echo "$APP"
