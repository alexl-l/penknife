#!/bin/zsh
# Runs Penknife's unit tests (PenknifeTests) and prints a short summary.
# Safe on this Mac: the test host starts no module (AppDelegate.isRunningTests), and the tests
# never change the microphone, press keys, use Accessibility or write the user's settings.
set -uo pipefail
cd "$(dirname "$0")/.."

result="${TMPDIR:-/tmp}/penknife-tests.xcresult"
rm -rf "$result"
xcodebuild test -quiet -project Penknife.xcodeproj -scheme Penknife \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath build.noindex \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    -only-testing:PenknifeTests -resultBundlePath "$result" > "${result%.xcresult}.log" 2>&1
code=$?

if [[ ! -d "$result" ]]; then
    echo "Tests did not run (build failed?). Log: ${result%.xcresult}.log"
    grep -E "error:" "${result%.xcresult}.log" | head -10
    exit 1
fi

xcrun xcresulttool get test-results summary --path "$result" | /usr/bin/python3 -I -c '
import json, sys
s = json.load(sys.stdin)
print("{}: {} passed, {} failed, {} skipped".format(s["result"], s["passedTests"], s["failedTests"], s["skippedTests"]))
for f in s.get("testFailures", []):
    print("  FAILED {}: {}".format(f["testName"], f["failureText"].splitlines()[0]))
'
exit $code
