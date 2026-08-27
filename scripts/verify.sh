#!/bin/bash
# Verify every surface. Slower than the per-surface scripts — run those while
# working, this one before opening a PR that spans surfaces.
# Does not run scripts/e2e.sh; that is the full-stack check.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILED=0

"$ROOT/scripts/verify-rules.sh"   || FAILED=1
"$ROOT/scripts/verify-api.sh"     || FAILED=1
"$ROOT/scripts/verify-website.sh" || FAILED=1
"$ROOT/scripts/verify-mobile.sh"  || FAILED=1

[ "$FAILED" -ne 0 ] && { echo "✗ verify FAILED"; exit 1; }
echo "✓ all surfaces verified"
