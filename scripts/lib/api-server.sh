# Shared helper: make sure the Eva API is reachable, and export where it lives.
#
# - If EVA_API_URL is set and healthy, use it as-is.
# - Otherwise boot `api/` on the first free port from EVA_API_PORT (default 3003,
#   matching the app's DEBUG base URL). Local ports are shared with whatever else
#   is running, so the probe below confirms it is *our* API before using one.
#
# Exports API_URL and EVA_API_URL (api/test reads the latter).

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
  if [ -n "$API_URL" ] && api_health "$API_URL"; then
    echo "▶ using API already running at $API_URL"
    export EVA_API_URL="$API_URL"
    return 0
  fi

  local start=${EVA_API_PORT:-3003} port=""
  for candidate in $(seq "$start" $((start + 10))); do
    if api_health "http://localhost:$candidate"; then
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
  API_LOG=$(mktemp -t eva-api-verify)
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
