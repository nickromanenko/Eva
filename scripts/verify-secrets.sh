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
#
# Runs in CI on every pull request and on `main` (`.github/workflows/check-secrets.yml`,
# #297), not only inside scripts/verify.sh. It reports there; it blocks a merge only once a
# human makes it a required check on `main` — a repository setting (ARCHITECTURE.md §6a).
# Keep it credential-free and history-free: CI runs it with `contents: read` and a
# depth-1 checkout.
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
  report "$f" "the local key directory (or a link to it) must never be committed — check whether it holds key material or only a link before rotating anything"
done < <(git ls-files -- '.secrets' '*/.secrets' '.secrets/*' '*/.secrets/*' 2>/dev/null)

# Content. `git grep` searches tracked files only, which is the set that matters.
#
# Every pattern goes in with `-e`: one starting with `-` is otherwise read as an option. The
# PEM pattern was, for as long as this script existed — git exited 129, `2>/dev/null` hid
# it, and the empty output read as "clean" (#301). So an exit status other than 0 (matches)
# or 1 (no matches) fails the check: a scan that did not run has not passed.
#
# `.env.example` holds deliberate placeholders; this script describes the patterns it hunts
# and would otherwise match itself.
EXCLUDES=(':!api/.env.example' ':!scripts/verify-secrets.sh')

# File names come back NUL-separated (`-z`), so a name with a newline, or one git would
# otherwise quote (non-ASCII, `"`), is the real path. Command substitution drops NULs and
# this must run on macOS's bash 3.2 (no `mapfile -d`), hence a file read with `read -d ''`.
MATCHES=$(mktemp) || { echo "✗ could not create a temporary file"; exit 1; }
trap 'rm -f "$MATCHES"' EXIT

# grep_files PATTERN — writes the matching tracked files to $MATCHES and returns git grep's
# status. A redirect that cannot be written exits 1, which would read as "no matches", so
# that case is refused first.
grep_files() {
  [ -w "$MATCHES" ] || return 2
  git grep -z -lIE -e "$1" -- . "${EXCLUDES[@]}" > "$MATCHES"
}

scan_failed() {
  report "git grep exited $1" "the scan for \"$2\" did not run — a check that cannot run has not passed"
}

scan() {
  local pattern="$1" why="$2" rc f
  grep_files "$pattern"
  rc=$?
  case $rc in
    0) while IFS= read -r -d '' f; do report "$f" "$why"; done < "$MATCHES" ;;
    1) ;;
    *) scan_failed "$rc" "$why" ;;
  esac
  return 0
}

# Private keys. A header alone is not a key: the tracked tree names the PEM header in prose
# (PROVIDER-SIGNIN.md, config.ts), in a placeholder, and in a test that assembles a PEM
# around a key it generates at run time. What makes a committed key is the body, so both
# forms below require base64 of real length straight after the header. The shortest key
# this repo handles, an EC P-256 `.p8`, opens with a full 64-character line; 40 leaves
# room for other wrappings and is still far longer than any placeholder.
PEM_HEADER='-----BEGIN [A-Z ]*PRIVATE KEY-----'
PEM_WHY="a private key is committed"

# On one line — a JSON `private_key` with escaped newlines, or an env value whose newlines
# became spaces. Single-quoted so the regex gets `\\n`, a literal backslash-n.
scan "${PEM_HEADER}"'((\\r)?\\n|[[:space:]]+)[A-Za-z0-9+/]{40}' "$PEM_WHY"

# Across lines, as a key file is written. `git grep` matches line by line, so it only finds
# the files with a header; awk then reads the lines after each header, past a legacy
# encrypted key's `Proc-Type:`/`DEK-Info:` lines and blank lines, for a base64 line. A body
# line may be pasted as a quoted source string (`"MIIE…`, `b'MIIE…`, a template literal) or
# a Markdown blockquote, so leading whitespace, `>`, an optional `b` and one quote go first.
# No interval expressions: macOS awk does not reliably support them.
#
# The file goes in as `./path`: awk reads an argument shaped like `name=value` as a variable
# assignment, not a file — and would then read stdin, which once held the remaining names
# (#303 review). `./` also keeps a leading `-` from being an option. Not `< "$1"`: a failed
# redirect exits 1, which would read as "no key body". stdin is /dev/null so nothing else
# can ever be read in its place.
pem_body_follows() {
  awk -v q="'" '
    /-----BEGIN [A-Z ]*PRIVATE KEY-----/ { look = 4; next }
    look > 0 {
      look--
      line = $0
      sub(/^[> \t]+/, "", line)
      sub("^b?[\"`" q "]", "", line)
      if (match(line, /^[A-Za-z0-9+\/]+/) && RLENGTH >= 40) { found = 1; exit }
      if (line == "" || line ~ /^[A-Za-z-]+: /) next
      look = 0
    }
    END { exit !found }
  ' "./$1" < /dev/null
}

grep_files "$PEM_HEADER"
rc=$?
case $rc in
  0)
    while IFS= read -r -d '' f; do
      pem_body_follows "$f"
      case $? in
        0) report "$f" "$PEM_WHY" ;;
        1) ;;
        *) report "$f" "could not be read to check for a private-key body — a check that cannot run has not passed" ;;
      esac
    done < "$MATCHES"
    ;;
  1) ;;
  *) scan_failed "$rc" "$PEM_WHY" ;;
esac

scan '"type": *"service_account"' "a service-account JSON is committed"
scan 'AIza[0-9A-Za-z_-]{35}' "a Google API key literal is committed"
# Postmark server tokens are UUIDs. Matching bare UUIDs would be far too broad, so this
# only fires when one sits next to a word that says what it is.
#
# `.`, not `[^\n]`: inside a bracket expression ERE has no escapes, so `[^\n]` meant
# "neither a backslash nor the letter n" and `postmark token: <uuid>` slipped through (#306).
# `git grep` matches line by line, so `.` cannot run past a newline anyway.
scan '([Pp]ostmark|POSTMARK).{0,40}[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
  "what looks like a Postmark server token is committed"

if [ "$FAILED" -ne 0 ]; then
  echo
  echo "✗ secrets check FAILED — GUARDRAILS 1"
  echo "  Removing the file is not the fix. Rotate the credential first: it is in history,"
  echo "  and history is what an attacker reads."
  exit 1
fi
echo "✓ no credentials in tracked files"
