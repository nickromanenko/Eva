#!/bin/bash
# Run the API suite the way CI runs it: against the Firebase emulators, holding no
# credentials and touching no real project (#67).
#
# `scripts/verify-api.sh` points at the REAL project and is still what you run locally —
# it is the higher-fidelity check and the one whose result the PR reports. This script is
# the same suite with the two Firebase endpoints redirected, so that a pull request from
# anyone, at any time, can be gated on it without a service account existing.
#
# What that costs is written down in docs/ARCHITECTURE.md §7 rather than implied here:
# the emulators are a reimplementation, so a green run proves our code against Firebase's
# model of Firebase, not against Google.
#
# Needs Java (the emulators are JVM processes) and the firebase CLI. Needs nothing else.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v java >/dev/null 2>&1; then
  echo "✗ api CI verify FAILED: java not found (the Firebase emulators need a JRE)"
  exit 1
fi

FIREBASE_BIN="${FIREBASE_CLI:-}"
if [ -z "$FIREBASE_BIN" ]; then
  if command -v firebase >/dev/null 2>&1; then
    FIREBASE_BIN="firebase"
  else
    FIREBASE_BIN="bunx firebase-tools"
  fi
fi

# A `demo-` prefix is what makes firebase-tools refuse to contact Google at all, whatever
# else is configured — the same guard scripts/verify-rules.sh relies on. It is the reason
# this script cannot reach production even if someone hands it real credentials.
PROJECT=demo-eva-api

# The API's own config (api/src/config.ts) is fail-fast and all-or-nothing, so every
# required variable has to be present even when the suite does not exercise it. None of
# these is a secret: the Auth emulator ignores the API key, and the JWT secret only has to
# be consistent within the run.
export FIREBASE_PROJECT_ID="$PROJECT"
export FIREBASE_WEB_API_KEY="emulator-ignores-this"
export JWT_SECRET="ci-only-not-a-secret"
export EMAIL_TRANSPORT=log
export POSTMARK_FROM="ci@example.test"
export PUBLIC_WEB_URL="http://localhost:4321"
# `log` writes whole links to stdout and config.ts refuses it under production; be explicit
# rather than depending on what the runner happens to set.
export NODE_ENV=test

# api_ensure_up REUSES any healthy Eva API it finds, starting at 3003 — which is where a
# dev server pointed at the real project usually is. Reusing that here would run "the
# emulated suite" against production and report it green. Take a port of our own.
unset EVA_API_URL
export EVA_API_PORT=3103

echo "▶ api tests (Auth + Firestore emulators, project $PROJECT)"
(cd "$ROOT/api" && bun install --frozen-lockfile >/dev/null) || {
  echo "✗ api CI verify FAILED: bun install"; exit 1;
}

# emulators:exec exports FIRESTORE_EMULATOR_HOST and FIREBASE_AUTH_EMULATOR_HOST into the
# child, which is how config.ts finds them — see `usingEmulators` there. verify-api.sh
# boots the server as its own child, so the server inherits them too.
(cd "$ROOT" && $FIREBASE_BIN emulators:exec \
  --project "$PROJECT" \
  --only auth,firestore \
  "scripts/verify-api.sh") || {
  echo "✗ api CI verify FAILED"; exit 1;
}
echo "✓ api CI verify passed"
