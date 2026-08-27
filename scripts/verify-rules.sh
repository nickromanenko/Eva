#!/bin/bash
# Verify the security rules: assert firestore.rules and storage.rules still deny
# everything, by running rules-tests/ against the Firestore and Storage
# emulators.
#
# Needs Java (the emulators are JVM processes) and the firebase CLI. Needs no
# credentials and no real Firebase project — the emulators run under the
# `demo-eva-rules` project id, which firebase-tools keeps entirely offline.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v java >/dev/null 2>&1; then
  echo "✗ rules verify FAILED: java not found (the Firebase emulators need a JRE)"
  exit 1
fi

# CI pins the CLI version via FIREBASE_CLI; locally we use whatever is on PATH.
FIREBASE_BIN="${FIREBASE_CLI:-}"
if [ -z "$FIREBASE_BIN" ]; then
  if command -v firebase >/dev/null 2>&1; then
    FIREBASE_BIN="firebase"
  else
    FIREBASE_BIN="bunx firebase-tools"
  fi
fi

echo "▶ rules tests (Firestore + Storage emulators)"
(cd "$ROOT/rules-tests" && bun install --frozen-lockfile >/dev/null) || {
  echo "✗ rules verify FAILED: bun install"; exit 1;
}

(cd "$ROOT" && $FIREBASE_BIN emulators:exec \
  --project demo-eva-rules \
  --only firestore,storage \
  "cd rules-tests && bun test") || {
  echo "✗ rules verify FAILED"; exit 1;
}
echo "✓ rules verify passed"
