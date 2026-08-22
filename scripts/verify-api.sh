#!/bin/bash
# Verify the API: typecheck, then integration tests against a running server.
# Boots the API itself if one isn't already listening. Non-zero exit on failure.
#
# Note: api/test/ hits the REAL Firebase project (accounts are created and swept
# under e2e+*@e2e.evaapp.dev). Needs api/.env and Application Default Credentials.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib/api-server.sh"

FAILED=0

echo "▶ typecheck"
(cd "$ROOT/api" && bun run typecheck) || FAILED=1

api_ensure_up || exit 1

echo "▶ API tests"
(cd "$ROOT/api" && bun test) || FAILED=1

[ "$FAILED" -ne 0 ] && { echo "✗ api verify FAILED"; exit 1; }
echo "✓ api verify passed"
