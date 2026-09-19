# Shared helper: make sure the Eva API is reachable, and export where it lives.
#
# - If EVA_API_URL is set and healthy, use it as-is.
# - Otherwise boot `api/` on the first free port from EVA_API_PORT (default 3003,
#   matching the app's DEBUG base URL). Local ports are shared with whatever else
#   is running, so the probe below confirms it is *our* API before using one.
#
# Exports API_URL and EVA_API_URL (api/test reads the latter).
#
# Reserved ports — the one list, so the next service does not collide (#112). The draw
# ranges belong to the test files that boot their own API and ask before taking a port.
#
#   3003          dev API (api_ensure_up default, and the app's DEBUG base URL)
#   3103–3113     scripts/ci-api.sh server window (EVA_API_PORT=3103)
#   3303          scripts/verify-mobile.sh UI-test mailbox (EVA_MAILBOX_PORT default)
#   3303–3313     scripts/ci-mobile.sh API window (EVA_API_PORT=3303) — which is why
#                 ci-mobile.sh overrides the mailbox to 3320 rather than the default above
#   3320          scripts/ci-mobile.sh UI-test mailbox (EVA_MAILBOX_PORT)
#   4321          website dev server (Astro)
#   8080/9099/9199  Firebase emulators (firestore/auth/hub)
#   3100–3299     api/test/events.test.ts draw range
#   3400–3599     api/test/today.test.ts draw range

API_URL=${EVA_API_URL:-}
API_STARTED=0
API_PID=""
API_LOG=""

# Identity probe, not just liveness: other dev servers happily answer /health,
# so we require the Eva API's own root response before pointing tests at a port.
api_health() { [ "$(curl -sf --max-time 2 "$1/" 2>/dev/null)" = "Eva API" ]; }

api_stop() {
  if [ "$API_STARTED" = "1" ] && [ -n "$API_PID" ]; then
    kill "$API_PID" 2>/dev/null || true
  fi
}

api_port_free() { ! lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

api_ensure_up() {
  # EVA_API_NO_REUSE: start our own server and never adopt one that happens to answer.
  # `api_health` can tell that something is an Eva API; it cannot tell which project that
  # API is pointed at. For scripts/ci-api.sh that difference is the whole point — adopting
  # a stray dev server would run "the emulated suite" against the real project and report
  # it green.
  if [ "${EVA_API_NO_REUSE:-0}" = "1" ]; then
    API_URL=""
  elif [ -n "$API_URL" ] && api_health "$API_URL"; then
    echo "▶ using API already running at $API_URL"
    export EVA_API_URL="$API_URL"
    return 0
  fi

  local start=${EVA_API_PORT:-3003} port=""
  for candidate in $(seq "$start" $((start + 10))); do
    if [ "${EVA_API_NO_REUSE:-0}" != "1" ] && api_health "http://localhost:$candidate"; then
      API_URL="http://localhost:$candidate"
      echo "▶ using API already running at $API_URL"
      export EVA_API_URL="$API_URL"
      return 0
    fi
    if [ -z "$port" ] && api_port_free "$candidate"; then port=$candidate; fi
  done

  if [ -z "$port" ]; then
    echo "✗ no free port in $start..$((start + 10)) — set EVA_API_PORT"
    return 1
  fi

  API_URL="http://localhost:$port"
  # A full template path, not `mktemp -t eva-api-verify`: BSD mktemp (macOS) reads `-t`'s
  # argument as a prefix, GNU coreutils (every Linux CI runner) requires the X's and
  # errors out — so the old form set API_LOG to the empty string and the redirect below
  # killed the server before it started. It had been broken on Linux since it was written
  # and could not be noticed, because nothing ran it on Linux until #67. Failing loudly
  # here rather than starting a server whose output goes nowhere.
  API_LOG=$(mktemp "${TMPDIR:-/tmp}/eva-api-verify.XXXXXX") || {
    echo "✗ could not create a log file for the API"; return 1;
  }
  echo "▶ starting API at $API_URL (logs: $API_LOG)"
  (cd "$ROOT/api" && PORT="$port" exec bun run src/index.ts) >"$API_LOG" 2>&1 &
  API_PID=$!
  API_STARTED=1
  trap api_stop EXIT

  for _ in $(seq 1 20); do
    api_health "$API_URL" && { export EVA_API_URL="$API_URL"; return 0; }
    sleep 0.5
  done
  echo "✗ API failed to start"
  cat "$API_LOG"
  return 1
}
