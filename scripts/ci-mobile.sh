#!/bin/bash
# Run the iOS suite the way CI runs it: against the Firebase emulators, holding no
# credentials and touching no real project — the same posture as scripts/ci-api.sh (#67).
#
# `scripts/verify-mobile.sh` points at the REAL project and stays what you run locally.
# This is the same build and the same XCUITest suite with the two Firebase endpoints
# redirected, so a pull request from anyone can be gated on it without a service account.
#
# Why it exists (#135): the UI suite ran on nobody's machine for at least two merges and
# collected three separate breakages, the first of which meant the target did not compile.
# Nothing said so, because ARCHITECTURE §6 records that nothing runs this in CI. It is also
# what makes AUTONOMY's merge condition 1 — "the suites actually ran" — meetable for a
# `mobile/` PR at all.
#
# Needs Java, the firebase CLI, xcodegen and Xcode with a simulator. The emulator caveat
# from ci-api.sh applies here too and for the same reason: a green run proves the app
# against Firebase's model of Firebase, not against Google.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v java >/dev/null 2>&1; then
  echo "✗ mobile CI verify FAILED: java not found (the Firebase emulators need a JRE)"
  exit 1
fi

# The emulated run must not inherit real-project configuration (#226, #208). CI has no
# `api/.env`; a local worktree that does would feed its real-project credentials into what
# is meant to be an emulator-only run. Refuse up front, in the #174 pattern, rather than
# discovering it as a spurious red suite three hundred lines in.
if [ -f "$ROOT/api/.env" ]; then
  echo "✗ mobile CI verify FAILED before running anything:"
  echo "  api/.env exists — the emulated suite must not inherit real-project credentials."
  echo "  Move it aside (or run from a clean checkout) and retry."
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

# A `demo-` prefix stops firebase-tools importing from or exporting to a real project and
# removes the login requirement — the same convention scripts/verify-rules.sh relies on.
# It does NOT constrain `api/src/identity-toolkit.ts`, which builds its own URL and calls
# `fetch`; what keeps that local is FIREBASE_AUTH_EMULATOR_HOST. config.ts refuses to boot
# unless both emulator hosts are set together, which is what actually closes that gap —
# without it the auth path fails *open*, silently falling back to real Google.
PROJECT=demo-eva-mobile

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

# **Provisioned, because unprovisioned is not the configuration that ships.**
#
# Without these, every provider path takes its `unconfigured` early return — the Google
# exchange and Apple's revocation both return before they build a request. That made the
# gate between `main` and production green for defects that only exist once the credentials
# are set: collapsing `classify` in `providers.ts` to always-`rejected` passed CI and would
# have turned a Google outage into every user being told their credential is bad, with no
# log line. The suites branch on `config` and assert the configured side too; they were
# simply never handed it.
#
# Nothing here is real and nothing leaves the process: `provider-signin.test.ts` and the two
# provider suites drive the routes in-process and stub `globalThis.fetch`, so no request
# reaches Google or Apple. The signing key is generated below, for this run only.
export GOOGLE_IOS_CLIENT_ID="ci-not-a-real-client.apps.googleusercontent.com"
export APPLE_CLIENT_ID="com.evaapp.ios"
export APPLE_TEAM_ID="CIONLYTEAM"
export APPLE_KEY_ID="CIONLYKEY1"

# A throwaway P-256 key, made here and never written to the repo — `appleClientSecret`
# needs one that actually imports, and the point is to exercise that path rather than skip
# it. Generated per run so there is nothing to leak and nothing to rotate.
APPLE_SIGNIN_KEY_PEM=$(openssl ecparam -genkey -name prime256v1 -noout 2>/dev/null \
  | openssl pkcs8 -topk8 -nocrypt 2>/dev/null)
if [ -z "$APPLE_SIGNIN_KEY_PEM" ]; then
  echo "✗ mobile CI verify FAILED: could not generate a throwaway P-256 key (needs openssl)"
  exit 1
fi
export APPLE_SIGNIN_KEY="$APPLE_SIGNIN_KEY_PEM"

# api_ensure_up REUSES any healthy Eva API it finds, and `api_health` can tell that
# something is an Eva API but not which project it points at. Reusing a stray dev server
# here would run "the emulated suite" against production and report it green. Refuse
# adoption outright rather than hoping a different port is enough — the port scan spans
# EVA_API_PORT..+10, so moving off 3003 narrows the window without closing it.
unset EVA_API_URL
export EVA_API_NO_REUSE=1


# **Distinct from ci-api.sh's, deliberately.** That script exports EVA_API_PORT=3103 and
# verify-mobile.sh defaults EVA_MAILBOX_PORT to 3103 — the collision #112 is filed about.
# Picking both explicitly here keeps this script correct whatever #112 decides, rather than
# inheriting a default that is already known to clash.
export EVA_API_PORT=3203
export EVA_MAILBOX_PORT=3303

echo "▶ mobile build + UI tests (Auth + Firestore emulators, project $PROJECT)"
(cd "$ROOT/api" && bun install --frozen-lockfile >/dev/null) || {
  echo "✗ mobile CI verify FAILED: bun install"; exit 1;
}

# emulators:exec exports FIRESTORE_EMULATOR_HOST and FIREBASE_AUTH_EMULATOR_HOST into the
# child; verify-mobile.sh boots the API and the UI-test mailbox as its own children, so both
# inherit them. config.ts refuses to boot unless both are set together, which is what keeps
# the auth path from failing open to real Google.
#
# refdata is seeded first (#226): the app's symptom picker draws from `GET /refdata`, and an
# empty emulator collection presents as `log.symptoms.unavailable` deep inside a UI test. The
# seed is the real script (`bun run seed:refdata`), not a fixture, so the emulated dataset
# cannot drift from the one users see; it exits non-zero on failure and the `&&` stops the
# suite before it runs, so a missing collection fails here with the seed's own message.
(cd "$ROOT" && $FIREBASE_BIN emulators:exec \
  --project "$PROJECT" \
  --only auth,firestore \
  "bash -c '(cd api && bun run seed:refdata) && scripts/verify-mobile.sh'") || {
  echo "✗ mobile CI verify FAILED"; exit 1;
}
echo "✓ mobile CI verify passed"
