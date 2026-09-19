#!/bin/bash
# End-to-end validation (spec §6): boots the API locally against the real
# Firebase project, runs API integration tests, runs the iOS UI sign-up test,
# then sweeps all e2e accounts. Non-zero exit on any failure.
set -uo pipefail
cd "$(dirname "$0")/.."

SIMULATOR=${EVA_SIMULATOR_ID:-D748EB89-9D96-4D48-9033-9AC0DA65FE7A}
API_LOG=$(mktemp -t eva-api-e2e)
MAILBOX_PORT=${EVA_MAILBOX_PORT:-3103}
MAILBOX_LOG=$(mktemp -t eva-mailbox-e2e)
MAILBOX_PID=""   # the trap below fires on any early exit, and `set -u` is on
FAILED=0

echo "▶ starting API (logs: $API_LOG)"
(cd api && exec bun run src/index.ts) >"$API_LOG" 2>&1 &
API_PID=$!
trap 'kill $API_PID $MAILBOX_PID 2>/dev/null' EXIT

for _ in $(seq 1 20); do
  curl -sf http://localhost:3003/health >/dev/null && break
  sleep 0.5
done
curl -sf http://localhost:3003/health >/dev/null || { echo "✗ API failed to start"; cat "$API_LOG"; exit 1; }

# Since #6 the UI test cannot sign in until an emailed link has been opened, which a
# simulator cannot do. Same loopback stand-in scripts/verify-mobile.sh starts; see
# api/scripts/uitest-mailbox.ts for why it is safe to have.
echo "▶ starting UI-test mailbox (logs: $MAILBOX_LOG)"
(cd api && PORT="$MAILBOX_PORT" EVA_API_URL=http://localhost:3003 \
  exec bun run scripts/uitest-mailbox.ts) >"$MAILBOX_LOG" 2>&1 &
MAILBOX_PID=$!
for _ in $(seq 1 20); do
  curl -sf "http://127.0.0.1:$MAILBOX_PORT/health" >/dev/null && break
  sleep 0.5
done
curl -sf "http://127.0.0.1:$MAILBOX_PORT/health" >/dev/null || {
  echo "✗ UI-test mailbox failed to start"; cat "$MAILBOX_LOG"; exit 1;
}

echo "▶ API integration tests"
(cd api && bun test) || FAILED=1

echo "▶ iOS UI test (sign-up → activation → questionnaire → dashboard)"
(cd mobile && xcodegen generate >/dev/null && \
  TEST_RUNNER_EVA_MAILBOX_URL="http://127.0.0.1:$MAILBOX_PORT" xcodebuild \
  -project Eva.xcodeproj -scheme Eva \
  -destination "id=$SIMULATOR" \
  -derivedDataPath build test) || FAILED=1

echo "▶ cleanup sweep"
(cd api && bun run ../scripts/e2e-cleanup.ts) || FAILED=1

if [ "$FAILED" -ne 0 ]; then
  echo "✗ e2e FAILED"
  exit 1
fi
echo "✓ e2e passed"
