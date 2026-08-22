#!/bin/bash
# End-to-end validation (spec §6): boots the API locally against the real
# Firebase project, runs API integration tests, runs the iOS UI sign-up test,
# then sweeps all e2e accounts. Non-zero exit on any failure.
set -uo pipefail
cd "$(dirname "$0")/.."

SIMULATOR=${EVA_SIMULATOR_ID:-D748EB89-9D96-4D48-9033-9AC0DA65FE7A}
API_LOG=$(mktemp -t eva-api-e2e)
FAILED=0

echo "▶ starting API (logs: $API_LOG)"
(cd api && exec bun run src/index.ts) >"$API_LOG" 2>&1 &
API_PID=$!
trap 'kill $API_PID 2>/dev/null' EXIT

for _ in $(seq 1 20); do
  curl -sf http://localhost:3000/health >/dev/null && break
  sleep 0.5
done
curl -sf http://localhost:3000/health >/dev/null || { echo "✗ API failed to start"; cat "$API_LOG"; exit 1; }

echo "▶ API integration tests"
(cd api && bun test) || FAILED=1

echo "▶ iOS UI test (sign-up → questionnaire → dashboard)"
(cd mobile && xcodegen generate >/dev/null && xcodebuild \
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
