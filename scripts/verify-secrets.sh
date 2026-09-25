#!/bin/bash
# Refuse to let a credential into the repository (GUARDRAILS 1).
#
# This exists because the rule failed. `AuthKey_V6JDCDQQG7.p8` — a live Apple signing key —
# was committed to the root and merged to `main` in #7, swept in by a blanket `git add -A`
# after PROVIDER-SIGNIN §3 told the operator to write it to the working directory. Nothing
# objected, because GUARDRAILS 1 was the one rule in that document with no mechanical check
# behind it. `.gitignore` is not that check: it does not cover an already-tracked file, it
# is bypassed by `git add -f`, and it only knows the patterns somebody thought to add.
#
# So this checks *content*, over tracked files only — what is committed is what matters, and
# an untracked scratch file is nobody's business.
#
# Deliberately not a general secret scanner. It looks for the shapes this repo actually
# handles, and every one of them is a literal that has no business being committed:
# private-key PEM blocks, service-account JSON, Google API keys, and Postmark's UUID-shaped
# server tokens. Adding a pattern is cheap; a false negative costs a rotation.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

FAILED=0
report() {
  echo "✗ $1"
  echo "  $2"
  FAILED=1
}

# Filenames that are a credential whatever is inside them.
while IFS= read -r f; do
  [ -z "$f" ] && continue
  report "$f" "an Apple signing key must never be committed; keep it outside the repo"
done < <(git ls-files -- '*.p8' 'AuthKey_*' 2>/dev/null)

# The local key directory, whatever its type. A worktree's `api/.secrets` symlink to the main
# checkout's keys was committed once (#295): the target stayed on disk, but a symlink, a file
# or a directory by that name has no business in the repo, and `.gitignore` cannot stop a
# path that is already tracked.
while IFS= read -r f; do
  [ -z "$f" ] && continue
  report "$f" "the local key directory (or a link to it) must never be committed"
done < <(git ls-files -- '.secrets' '*/.secrets' '.secrets/*' '*/.secrets/*' 2>/dev/null)

# Content. `git grep` searches tracked files only, which is the set that matters.
scan() {
  local pattern="$1" why="$2" out
  # `.env.example` holds deliberate placeholders; this script describes the patterns it
  # hunts and would otherwise match itself.
  out=$(git grep -lIE "$pattern" -- . \
        ':!api/.env.example' ':!scripts/verify-secrets.sh' 2>/dev/null)
  [ -n "$out" ] && while IFS= read -r f; do report "$f" "$why"; done <<< "$out"
  return 0
}

scan '-----BEGIN [A-Z ]*PRIVATE KEY-----' "a private key is committed"
scan '"type": *"service_account"' "a service-account JSON is committed"
scan 'AIza[0-9A-Za-z_-]{35}' "a Google API key literal is committed"
# Postmark server tokens are UUIDs. Matching bare UUIDs would be far too broad, so this
# only fires when one sits next to a word that says what it is.
scan '(postmark|POSTMARK)[^\n]{0,40}[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
  "what looks like a Postmark server token is committed"

if [ "$FAILED" -ne 0 ]; then
  echo
  echo "✗ secrets check FAILED — GUARDRAILS 1"
  echo "  Removing the file is not the fix. Rotate the credential first: it is in history,"
  echo "  and history is what an attacker reads."
  exit 1
fi
echo "✓ no credentials in tracked files"
