#!/bin/bash
# Verify the iOS app: regenerate the project, build, and run the UI tests.
#
#   scripts/verify-mobile.sh            build + UI tests (boots the API if needed)
#   scripts/verify-mobile.sh --build    compile every target, run nothing: no simulator
#                                       tests, no API, no emulators
#
# Simulator: override with EVA_SIMULATOR_ID (default matches scripts/e2e.sh).
#
# Do NOT add CODE_SIGNING_ALLOWED=NO: an unsigned app gets no Keychain
# entitlement, KeychainTokenStore silently fails to persist the JWT, and every
# authorized request then goes out without a bearer token (401).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib/api-server.sh"

BUILD_ONLY=0
[ "${1:-}" = "--build" ] && BUILD_ONLY=1
# `--build` compiles only — no API, no emulators, no node_modules. The full run boots the
# API, so only it needs the pre-flight (#208): a worktree's missing node_modules or a
# relative GOOGLE_APPLICATION_CREDENTIALS would otherwise fail deep inside sign-up and read
# as a regression.
[ "$BUILD_ONLY" = "0" ] && { preflight || exit 1; }

SIMULATOR=${EVA_SIMULATOR_ID:-D748EB89-9D96-4D48-9033-9AC0DA65FE7A}
# The destination names platform and arch explicitly (#230). A bare `id=` matches the same
# udid under both arm64 and x86_64, so xcodebuild warns "using the first of multiple
# matching destinations" and an operator cannot say which binary was built. arm64 is the
# native arch everywhere Xcode 26 runs — it dropped Intel — so the pin is stable, not a guess.
# The result bundle has a fixed name so `test-mobile.yml` can upload it (#228): the default
# lands at a timestamped path under the derived data and cannot be found without a glob.
# `mobile/build/` is gitignored. Removed first so a local re-run does not hit "already exists".
RESULT_BUNDLE="$ROOT/mobile/build/Eva.xcresult"
rm -rf "$RESULT_BUNDLE"
FAILED=0

command -v xcodegen >/dev/null || { echo "✗ xcodegen missing — brew install xcodegen"; exit 1; }

echo "▶ xcodegen generate"
# Eva/Info.plist is generated but tracked, because it is the only reviewable surface for
# what XcodeGen decides on your behalf — Eva.xcodeproj is gitignored. That only works if
# the copy in the tree is what regeneration actually produces.
#
# This is also the guard for #42, and the reason a #4-style "no unsubstituted $(" check
# would not have caught it: that bug was an *absent* key in project.yml, for which XcodeGen
# supplied a perfectly well-formed `1.0`. Nothing in the built bundle looked wrong.
#
# Compares before/after regeneration rather than against HEAD, so an intentional
# uncommitted change is fine and only a stale or hand-edited file fails.
PLIST="$ROOT/mobile/Eva/Info.plist"
PLIST_BEFORE=$(mktemp -t eva-infoplist)
cp "$PLIST" "$PLIST_BEFORE" 2>/dev/null || true

(cd "$ROOT/mobile" && xcodegen generate >/dev/null) || { echo "✗ xcodegen failed"; exit 1; }

if ! diff -q "$PLIST_BEFORE" "$PLIST" >/dev/null 2>&1; then
  echo "✗ mobile/Eva/Info.plist was stale — xcodegen regenerated it differently."
  echo "  Hand edits are silently reverted; change mobile/project.yml instead, then commit"
  echo "  the regenerated plist alongside it."
  diff "$PLIST_BEFORE" "$PLIST" || true
  rm -f "$PLIST_BEFORE"
  exit 1
fi
rm -f "$PLIST_BEFORE"

if [ "$BUILD_ONLY" = "1" ]; then
  echo "▶ build only (app + test targets, nothing run)"
  # **`build-for-testing`, not `build`.** The Eva scheme lists only the app under
  # `build:`; EvaTests and EvaUITests are under `test:`. So plain `build` compiled the app
  # and nothing else, and this flag — the whole of what a pull request runs (#158) —
  # could not see a test target that did not compile.
  #
  # It could not see it for nine files and several merges. `EvaUITests` had never once
  # compiled under CI's Xcode 16.4: every XCUITest API is `@MainActor` in the SDK and the
  # suites were nonisolated, which 16.4 rejects and 26.2 waves through as a warning. The
  # `Full suite` job caught it on every push from the day it landed and failed every time;
  # the pull requests that added to it were green, because this line built the app.
  #
  # `build-for-testing` compiles the test targets and stops — it boots no simulator, needs
  # no API and no emulators, and runs not one test. That division is deliberate and is
  # #158's: the pull request compiles, `main` and the nightly run. This moves where the
  # compile *ends*, not what runs.
  (cd "$ROOT/mobile" && xcodebuild \
    -project Eva.xcodeproj -scheme Eva \
    -destination "platform=iOS Simulator,id=$SIMULATOR,arch=arm64" \
    -derivedDataPath build -resultBundlePath "$RESULT_BUNDLE" build-for-testing) || FAILED=1
else
  # The UI test signs up for real, so it needs the API up.
  api_ensure_up || exit 1

  # …and, since #6, an account cannot sign in until an emailed link has been opened,
  # which a simulator cannot do. `api/scripts/uitest-mailbox.ts` is the stand-in: it is
  # started here, on loopback, and torn down with this script. See its header for why it
  # is safe to have at all.
  MAILBOX_PORT=${EVA_MAILBOX_PORT:-3103}
  MAILBOX_URL="http://127.0.0.1:$MAILBOX_PORT"
  MAILBOX_LOG=$(mktemp -t eva-mailbox)
  (cd "$ROOT/api" && PORT="$MAILBOX_PORT" EVA_API_URL="$API_URL" \
    exec bun run scripts/uitest-mailbox.ts) >"$MAILBOX_LOG" 2>&1 &
  MAILBOX_PID=$!
  mailbox_stop() { kill "$MAILBOX_PID" 2>/dev/null || true; api_stop; }
  trap mailbox_stop EXIT

  MAILBOX_UP=0
  for _ in $(seq 1 20); do
    if [ "$(curl -sf --max-time 2 "$MAILBOX_URL/health" 2>/dev/null)" = "Eva UI-test mailbox" ]; then
      MAILBOX_UP=1; break
    fi
    sleep 0.5
  done
  [ "$MAILBOX_UP" = "1" ] || { echo "✗ UI-test mailbox failed to start"; cat "$MAILBOX_LOG"; exit 1; }
  echo "▶ UI-test mailbox at $MAILBOX_URL"

  echo "▶ build + UI tests (simulator $SIMULATOR, API $API_URL)"
  # xcodebuild forwards environment variables prefixed TEST_RUNNER_ into the UI
  # test runner with the prefix stripped; the test then hands EVA_API_BASE_URL to
  # app.launchEnvironment. It must be an env var — as a build setting it is ignored.
  #
  # **The mailbox is handed the address it actually binds, not `localhost`** (#220). It
  # binds `127.0.0.1` and only that, on purpose — it activates accounts, so its header
  # keeps it off every interface but loopback. `localhost` resolves `::1` first on the
  # simulator, so advertising it left the runner racing a v6 connection refused against a
  # v4 retry: sometimes activation landed, sometimes `activate` burned its 30s and the
  # whole suite died at the gate. The fault is the asymmetry between the advertised and
  # the bound address, and this closes it from the advertising side — widening the bind
  # would close it by giving a thing that activates accounts a wider door.
  (cd "$ROOT/mobile" && TEST_RUNNER_EVA_API_BASE_URL="$API_URL" \
    TEST_RUNNER_EVA_MAILBOX_URL="$MAILBOX_URL" xcodebuild \
    -project Eva.xcodeproj -scheme Eva \
    -destination "platform=iOS Simulator,id=$SIMULATOR,arch=arm64" \
    -derivedDataPath build -resultBundlePath "$RESULT_BUNDLE" test) || FAILED=1

  echo "▶ cleanup sweep (e2e accounts created by the UI test)"
  (cd "$ROOT/api" && bun run "$ROOT/scripts/e2e-cleanup.ts") || FAILED=1
fi

[ "$FAILED" -ne 0 ] && { echo "✗ mobile verify FAILED"; exit 1; }
echo "✓ mobile verify passed"
