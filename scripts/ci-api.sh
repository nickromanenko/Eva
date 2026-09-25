#!/bin/bash
# Run the API suite the way CI runs it: against the Firebase emulators, holding no
# credentials and touching no real project (#67).
#
# `scripts/verify-api.sh` points at the REAL project — the higher-fidelity check, required
# on auth-boundary changes and at least weekly (GUARDRAILS 15). This script is the same
# suite with the two Firebase endpoints redirected, and since 2026-09-25 it is the per-PR
# gate: a pull request from anyone, at any time, can be gated on it without a service
# account existing.
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

# **The cycle maths' constants (C11, #176), for the same reason the provider credentials
# above are set: unconfigured is not the configuration that ships.**
#
# Left unset, `config.cycle` is `null`, `analyzeCycles` refuses, and every cycle path in the
# suite takes its refusal branch — so a defect that only exists once the constants are
# present would pass this gate. These are not secrets and not placeholders: they are the
# values PRD §Predictions in Cycle mode settled on 2026-08-30 (A25–A27) and the period gap
# #186 decided, the same ones `api/.env.example` carries, so CI runs the configuration
# production is meant to run. The group is all-or-nothing at boot, so a variable missing
# here fails every suite that loads `config.ts` rather than quietly skipping the maths.
export CYCLE_MIN_LENGTH_DAYS=21
export CYCLE_MAX_LENGTH_DAYS=45
export CYCLE_MIN_PERIOD_GAP_DAYS=2
export CYCLE_HISTORY_CYCLES=6
export CYCLE_MIN_CYCLES_FOR_ESTIMATE=3
export CYCLE_NARROW_BAND_MIN_CYCLES=6
export CYCLE_LUTEAL_PHASE_DAYS=14
export CYCLE_FERTILE_DAYS_BEFORE_OVULATION=5
export CYCLE_FERTILE_DAYS_AFTER_OVULATION=1
export CYCLE_PEAK_DAYS_BEFORE_OVULATION=2
export CYCLE_IRREGULAR_YOUNG_MAX_AGE=25
export CYCLE_IRREGULAR_MID_MAX_AGE=41
export CYCLE_IRREGULAR_YOUNG_VARIATION_DAYS=9
export CYCLE_IRREGULAR_MID_VARIATION_DAYS=7
export CYCLE_IRREGULAR_OLDER_VARIATION_DAYS=9

# **The nutrition targets engine's constants (S2, #222), for the same reason as the block
# above.** Left unset, `config.nutrition` is `null` and `planDailyTargets` refuses, so every
# nutrition path in the suite would take its refusal branch and a defect that only exists once
# the constants are present would pass this gate. Nothing here is a secret or a placeholder:
# they are the values PRD Daily targets calculation settled (A29, A30) plus the four points
# #222 chose inside a range, the same ones `api/.env.example` carries with their sources. The
# group is all-or-nothing at boot, so a variable missing here fails every suite that loads
# `config.ts` rather than quietly skipping the maths.
export NUTRITION_BMR_PER_KG=10
export NUTRITION_BMR_PER_CM=6.25
export NUTRITION_BMR_PER_YEAR=5
export NUTRITION_BMR_OFFSET=161
export NUTRITION_ACTIVITY_FACTOR_MOSTLY_SITTING=1.2
export NUTRITION_ACTIVITY_FACTOR_LIGHTLY_ACTIVE=1.375
export NUTRITION_ACTIVITY_FACTOR_ACTIVE=1.55
export NUTRITION_ACTIVITY_FACTOR_VERY_ACTIVE=1.725
export NUTRITION_ADJUST_LOSE=-0.15
export NUTRITION_ADJUST_GAIN=0.15
export NUTRITION_ADJUST_BUILD_MUSCLE=0.1
export NUTRITION_PROTEIN_LOSE_G_PER_KG=1.6
export NUTRITION_PROTEIN_BUILD_MUSCLE_G_PER_KG=1.8
export NUTRITION_PROTEIN_OTHER_G_PER_KG=1.2
export NUTRITION_FAT_MIN_FRACTION=0.2
export NUTRITION_FIBRE_G=25
export NUTRITION_FIBRE_RAISED_G=30
export NUTRITION_MIN_BMI=18.5
export NUTRITION_MAX_PLAN_LOSS_FRACTION=0.15
export NUTRITION_MAX_LOSS_KG_PER_WEEK=0.5
export NUTRITION_MAX_LOSS_FRACTION_PER_WEEK=0.01
export NUTRITION_MIN_CALORIE_KCAL=1200
export NUTRITION_KCAL_PER_KG_BODY_MASS=7700

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
