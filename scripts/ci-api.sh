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

# A `demo-` prefix stops firebase-tools importing from or exporting to a real project and
# removes the login requirement — the same convention scripts/verify-rules.sh relies on.
# It does NOT constrain `api/src/identity-toolkit.ts`, which builds its own URL and calls
# `fetch`; what keeps that local is FIREBASE_AUTH_EMULATOR_HOST. config.ts refuses to boot
# unless both emulator hosts are set together, which is what actually closes that gap —
# without it the auth path fails *open*, silently falling back to real Google.
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
  echo "✗ api CI verify FAILED: could not generate a throwaway P-256 key (needs openssl)"
  exit 1
fi
export APPLE_SIGNIN_KEY="$APPLE_SIGNIN_KEY_PEM"

# api_ensure_up REUSES any healthy Eva API it finds, and `api_health` can tell that
# something is an Eva API but not which project it points at. Reusing a stray dev server
# here would run "the emulated suite" against production and report it green. Refuse
# adoption outright rather than hoping a different port is enough — the port scan spans
# EVA_API_PORT..+10, so moving off 3003 narrows the window without closing it.
unset EVA_API_URL
export EVA_API_PORT="${EVA_API_PORT:-3103}"
export EVA_API_NO_REUSE=1

# Refuse to start if anything already holds a port this run needs (#112).
#
# Without this the run does not fail — it produces a *green-looking script* full of red
# tests. A second agent holding 3103 and 8080 gave 190 pass / 117 fail in 13.7s, every
# failure `ECONNREFUSED` under a stack trace, on a tree whose typecheck was clean and
# whose CI was green. 117 red tests on a rebase is indistinguishable from a broken
# rebase, and the reasonable next move is to start editing code that was never broken.
# Failing here costs one line of output instead.
#
# The emulator ports come from firebase.json rather than from this script, so they are
# read back out of it rather than restated — a port changed there must not silently stop
# being checked here.
EMULATOR_PORTS="$(python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    emu = json.load(f).get("emulators", {})
for name in ("auth", "firestore"):
    port = emu.get(name, {}).get("port")
    if port:
        print(f"{port} {name} emulator")
' "$ROOT/firebase.json" 2>/dev/null)"

BUSY=""
while read -r port label; do
  [ -z "$port" ] && continue
  if lsof -ti:"$port" >/dev/null 2>&1; then
    BUSY="${BUSY}  port $port ($label) is already in use"$'\n'
  fi
done <<EOF
$EVA_API_PORT this script's API server
$EMULATOR_PORTS
EOF

if [ -n "$BUSY" ]; then
  echo "✗ api CI verify FAILED before running anything:"
  printf '%s' "$BUSY"
  echo
  echo "  Something else is using them — most likely another agent or terminal running"
  echo "  scripts/ci-api.sh or scripts/verify-mobile.sh on this machine (#112, #162)."
  echo "  Nothing was run, so nothing here says anything about your code."
  echo
  echo "  Wait for the other run to finish, or set EVA_API_PORT to a free port. The"
  echo "  emulator ports come from firebase.json and are shared by every run on this"
  echo "  machine, so two runs still cannot overlap — this only tells you which."
  exit 1
fi

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
