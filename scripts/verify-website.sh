#!/bin/bash
# Verify the website: a clean Astro production build.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "▶ astro build"
(cd "$ROOT/website" && bun install --frozen-lockfile && bun run build) || {
  echo "✗ website verify FAILED"; exit 1;
}
echo "✓ website verify passed"
