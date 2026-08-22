#!/bin/bash
# Verify the iOS app: regenerate the project, build, and run the UI tests.
#
#   scripts/verify-mobile.sh            build + UI tests (boots the API if needed)
#   scripts/verify-mobile.sh --build    build only, no simulator tests, no API
#
# Simulator: override with EVA_SIMULATOR_ID (default matches scripts/e2e.sh).
#
# Do NOT add CODE_SIGNING_ALLOWED=NO: an unsigned app gets no Keychain
# entitlement, KeychainTokenStore silently fails to persist the JWT, and every
# authorized request then goes out without a bearer token (401).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib/api-server.sh"

SIMULATOR=${EVA_SIMULATOR_ID:-D748EB89-9D96-4D48-9033-9AC0DA65FE7A}
BUILD_ONLY=0
[ "${1:-}" = "--build" ] && BUILD_ONLY=1
FAILED=0

command -v xcodegen >/dev/null || { echo "✗ xcodegen missing — brew install xcodegen"; exit 1; }

echo "▶ xcodegen generate"
(cd "$ROOT/mobile" && xcodegen generate >/dev/null) || { echo "✗ xcodegen failed"; exit 1; }

if [ "$BUILD_ONLY" = "1" ]; then
  echo "▶ build only"
  (cd "$ROOT/mobile" && xcodebuild \
    -project Eva.xcodeproj -scheme Eva \
    -destination "id=$SIMULATOR" \
    -derivedDataPath build build) || FAILED=1
else
  # The UI test signs up for real, so it needs the API up.
  api_ensure_up || exit 1
  echo "▶ build + UI tests (simulator $SIMULATOR, API $API_URL)"
  # xcodebuild forwards environment variables prefixed TEST_RUNNER_ into the UI
  # test runner with the prefix stripped; the test then hands EVA_API_BASE_URL to
  # app.launchEnvironment. It must be an env var — as a build setting it is ignored.
  (cd "$ROOT/mobile" && TEST_RUNNER_EVA_API_BASE_URL="$API_URL" xcodebuild \
    -project Eva.xcodeproj -scheme Eva \
    -destination "id=$SIMULATOR" \
    -derivedDataPath build test) || FAILED=1

  echo "▶ cleanup sweep (e2e accounts created by the UI test)"
  (cd "$ROOT/api" && bun run "$ROOT/scripts/e2e-cleanup.ts") || FAILED=1
fi

[ "$FAILED" -ne 0 ] && { echo "✗ mobile verify FAILED"; exit 1; }
echo "✓ mobile verify passed"
