#!/bin/bash
# Run the actual controller and Keychain adapter against in-memory fakes.
# Requires full Xcode, but no TV, real credentials, xcodegen or network access.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CRISP_DEV_DIR="$(xcode-select -p)"
CRISP_TEST_BASE="$CRISP_DEV_DIR/Platforms/MacOSX.platform/Developer"
CRISP_TEST_LIB="$CRISP_TEST_BASE/usr/lib"
CRISP_TEST_FRAMEWORKS="$CRISP_TEST_BASE/Library/Frameworks"
CRISP_TEST_PRIVATE="$CRISP_TEST_BASE/Library/PrivateFrameworks"
test -d "$CRISP_TEST_LIB/XCTest.swiftmodule" || {
    echo "Select full Xcode with xcode-select before running these tests." >&2
    exit 1
}
mkdir -p build/webos-tests-runner
cat > build/webos-tests-runner/main.swift <<'SWIFT'
import XCTest
let suite = XCTestSuite(name: "LG webOS regression tests")
suite.addTest(LGWebOSProtocolTests.defaultTestSuite)
suite.addTest(LGWebOSVolumeControllerTests.defaultTestSuite)
suite.addTest(LGWebOSKeyStoreTests.defaultTestSuite)
suite.run()
exit(suite.testRun?.totalFailureCount == 0 ? 0 : 1)
SWIFT
xcrun swiftc -swift-version 6 -warnings-as-errors -module-cache-path build/ModuleCache \
    -I "$CRISP_TEST_LIB" -L "$CRISP_TEST_LIB" -F "$CRISP_TEST_FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$CRISP_TEST_LIB" \
    -Xlinker -rpath -Xlinker "$CRISP_TEST_FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$CRISP_TEST_PRIVATE" \
    Crisp/Models/LGWebOSProtocol.swift \
    Crisp/Services/LGWebOSKeyStore.swift Crisp/Services/LGWebOSTransport.swift \
    Crisp/Services/LGWebOSVolumeController.swift CrispTests/LGWebOS*Tests.swift \
    build/webos-tests-runner/main.swift -o build/webos-tests-runner/tests
build/webos-tests-runner/tests
