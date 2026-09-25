#!/bin/bash
# The test of scripts/verify-secrets.sh (#310).
#
# The fixes in #301 and #306 were verified by hand in scratch clones: PEM layouts, awkward
# file names, `-z`, the exit-status checks. None of that lived in the repo, so an edit
# that quietly broke one of them would still have printed "✓ no credentials". This keeps
# those cases in the repo, and CI runs them under Ubuntu's mawk
# (`.github/workflows/check-secrets.yml`), where the script's awk had never run on
# anything but a clean tree.
#
# Bash rather than `bun test`: the subject is a bash script that has to work on macOS's
# bash 3.2 and on Ubuntu, and a bash test runs in both with no toolchain. The CI job stays
# a checkout plus a shell step.
#
# What it does:
#   1. Generates keys at run time (openssl; ssh-keygen for the OpenSSH format) in a
#      temporary directory. No key, and no literal that would trip the scanner, is in this
#      file — the scanner runs over it like any other tracked file.
#   2. Builds a throwaway git repo holding a copy of the script, and for each case stages
#      the case's files, runs the script, and asserts the exit status and the reason.
#   3. Runs the whole suite again against mutated copies of the script — no `-z`, no `./`
#      before awk's file, no exit-status check in either scan — and requires each to fail.
#      A test that passes against a broken script is not testing it. If a mutation no
#      longer applies because the script changed, that is a failure too: update the
#      mutation along with the script.
#
# Usage: scripts/test-verify-secrets.sh           (the real script plus its mutants)
#        scripts/test-verify-secrets.sh SCRIPT    (the suite once, against SCRIPT)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="$ROOT/scripts/verify-secrets.sh"

for tool in git openssl ssh-keygen awk; do
  command -v "$tool" >/dev/null || { echo "✗ $tool is required"; exit 1; }
done

WORK=$(mktemp -d) || { echo "✗ could not create a temporary directory"; exit 1; }
trap 'rm -rf "$WORK"' EXIT

# ─── Keys, generated now and deleted with $WORK ────────────────────────────────────────
K="$WORK/keys"
mkdir -p "$K"
gen() { "$@" 2>/dev/null || { echo "✗ key generation failed: $*"; exit 1; }; }
gen openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$K/rsa-pkcs8.pem"
gen openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$K/ec-pkcs8.pem"
gen openssl ecparam -name prime256v1 -genkey -noout -out "$K/ec-sec1.pem"
gen openssl rsa -in "$K/rsa-pkcs8.pem" -aes128 -passout pass:throwaway -traditional \
  -out "$K/rsa-legacy-encrypted.pem"
gen ssh-keygen -q -t ed25519 -N '' -C throwaway -f "$K/openssh"
grep -q '^Proc-Type: 4,ENCRYPTED' "$K/rsa-legacy-encrypted.pem" \
  || { echo "✗ openssl did not write a legacy encrypted key"; exit 1; }

# One line with escaped newlines, as in a service-account JSON's `private_key`.
json_escaped() { awk '{ printf "%s\\n", $0 }' "$1"; }
UUID=$(openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')
# Assembled so neither literal appears in this file.
AIZA="AI""za$(openssl rand -hex 18 | cut -c1-35)"
SA_TYPE='"type": "service_''account"'

# ─── The throwaway repo ─────────────────────────────────────────────────────────────────
REPO="$WORK/repo"
mkdir -p "$REPO/scripts" "$REPO/api"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" config user.name test
git -C "$REPO" config commit.gpgsign false
cp "$ROOT/api/.env.example" "$REPO/api/.env.example"
echo "# Eva" > "$REPO/README.md"

# A shim that makes one `git grep` fail, chosen by FAIL_GREP_ARG (an exact argument), and
# leaves a mark so a case can tell the shim fired rather than the pattern having moved.
REAL_GIT=$(command -v git)
mkdir -p "$WORK/shim"
cat > "$WORK/shim/git" <<EOF
#!/bin/bash
if [ "\${1:-}" = grep ] && [ -n "\${FAIL_GREP_ARG:-}" ]; then
  for a in "\$@"; do
    if [ "\$a" = "\$FAIL_GREP_ARG" ]; then touch "$WORK/shim-fired"; echo "fatal: forced" >&2; exit 128; fi
  done
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$WORK/shim/git"

# ─── The suite ──────────────────────────────────────────────────────────────────────────
PEM_WHY="a private key is committed"
PM_WHY="what looks like a Postmark server token is committed"
FAILS=0
QUIET=0
OUT="$WORK/out"

fail() {
  FAILS=$((FAILS + 1))
  [ "$QUIET" -eq 1 ] && return
  echo "✗ $1"
  sed 's/^/    | /' "$OUT"
}

reset_repo() {
  git -C "$REPO" reset -q --hard
  git -C "$REPO" clean -qfdx
  rm -f "$WORK/shim-fired"
}

# run_script [ENV=VALUE ...] — the script as CI runs it, from the repo's own scripts/.
run_script() {
  (cd "$REPO" && env "$@" scripts/verify-secrets.sh) > "$OUT" 2>&1
}

# expect_detected NAME WHY PATH... — stage PATH..., which the case has written, and require
# the script to fail with WHY. Not any failure: "could not be read" or "git grep exited"
# means the scan broke, not that it found the key.
expect_detected() {
  local name="$1" why="$2" rc
  shift 2
  git -C "$REPO" add -f -- "$@"
  run_script
  rc=$?
  if [ "$rc" -ne 1 ]; then
    fail "$name: expected exit 1, got $rc"
  elif ! grep -qF "$why" "$OUT"; then
    fail "$name: failed, but not with \"$why\""
  elif grep -qE 'could not be read|git grep exited' "$OUT"; then
    fail "$name: reported a scan error as well as the finding"
  fi
  reset_repo
}

# pem_file PATH KEY — a key file, written as a key file is.
pem_file() { cp "$2" "$REPO/$1"; }

suite() {
  local script="$1" rc
  FAILS=0
  cp "$script" "$REPO/scripts/verify-secrets.sh"
  chmod +x "$REPO/scripts/verify-secrets.sh"
  git -C "$REPO" add -- README.md api/.env.example scripts/verify-secrets.sh
  git -C "$REPO" commit -qm baseline
  reset_repo

  # Clean tree, with near-misses that must not fire: a PEM header in prose, a placeholder
  # body too short to be a key, the word Postmark without a UUID, a UUID without it.
  printf 'Paste the key, from -----BEGIN PRIVATE KEY----- to the END line.\n' > "$REPO/prose.md"
  printf -- '-----BEGIN PRIVATE KEY-----\nMIIEplaceholder\n-----END PRIVATE KEY-----\n' > "$REPO/placeholder.pem"
  printf 'postmark token: set it in Secret Manager\nrequest id %s\n' "$UUID" > "$REPO/notes.txt"
  git -C "$REPO" add -- prose.md placeholder.pem notes.txt
  run_script
  rc=$?
  if [ "$rc" -ne 0 ] || ! grep -qF "✓ no credentials in tracked files" "$OUT"; then
    fail "clean tree: expected exit 0 and a pass, got $rc"
  fi
  reset_repo

  # PEM files, one per format this repo could meet.
  pem_file rsa.pem "$K/rsa-pkcs8.pem";              expect_detected "PKCS#8 RSA" "$PEM_WHY" rsa.pem
  pem_file ec.pem "$K/ec-pkcs8.pem";                expect_detected "PKCS#8 EC" "$PEM_WHY" ec.pem
  pem_file ec-sec1.pem "$K/ec-sec1.pem";            expect_detected "SEC1 EC" "$PEM_WHY" ec-sec1.pem
  pem_file id_ed25519 "$K/openssh";                 expect_detected "OpenSSH" "$PEM_WHY" id_ed25519
  pem_file legacy.pem "$K/rsa-legacy-encrypted.pem"; expect_detected "legacy encrypted RSA" "$PEM_WHY" legacy.pem

  # One-line JSON `private_key`, without the service-account type so only the PEM scan can fire.
  printf '{"private_key": "%s"}\n' "$(json_escaped "$K/ec-pkcs8.pem")" > "$REPO/key.json"
  expect_detected "one-line JSON private_key" "$PEM_WHY" key.json

  # Split across quoted string literals, as when a key is pasted into source.
  awk '{ printf "  \"%s\\n\" +\n", $0 } END { print "  \"\";" }' "$K/rsa-pkcs8.pem" \
    | { echo 'const key ='; cat; } > "$REPO/key.ts"
  expect_detected "split string literal" "$PEM_WHY" key.ts

  # Awkward names, all through the multi-line (awk) path. `a=b` is what awk reads as an
  # assignment without the `./`; `-lead` as an option.
  pem_file 'a=b.pem' "$K/ec-pkcs8.pem";             expect_detected "file named a=b" "$PEM_WHY" 'a=b.pem'
  pem_file '-lead.pem' "$K/ec-pkcs8.pem";           expect_detected "file named -lead" "$PEM_WHY" '-lead.pem'
  pem_file 'clé.pem' "$K/ec-pkcs8.pem";             expect_detected "non-ASCII file name" "$PEM_WHY" 'clé.pem'
  pem_file $'new\nline.pem' "$K/ec-pkcs8.pem";      expect_detected "file name with a newline" "$PEM_WHY" $'new\nline.pem'

  # Postmark (#306): a label containing an `n` between the word and the token.
  printf 'postmark token: %s\n' "$UUID" > "$REPO/pm1.txt"
  expect_detected "postmark token: <uuid>" "$PM_WHY" pm1.txt
  printf 'POSTMARK_API_KEY=%s\n' "$UUID" > "$REPO/pm2.env"
  expect_detected "POSTMARK_API_KEY=<uuid>" "$PM_WHY" pm2.env
  printf '{"postmarkToken": "%s"}\n' "$UUID" > "$REPO/pm3.json"
  expect_detected "JSON postmarkToken" "$PM_WHY" pm3.json

  # The other shapes, once each.
  printf '{%s, "project_id": "x"}\n' "$SA_TYPE" > "$REPO/sa.json"
  expect_detected "service-account JSON" "a service-account JSON is committed" sa.json
  printf 'key = "%s"\n' "$AIZA" > "$REPO/google.txt"
  expect_detected "Google API key" "a Google API key literal is committed" google.txt
  echo 'not a key' > "$REPO/AuthKey_TEST.p8"
  expect_detected "AuthKey .p8 by name" "an Apple signing key must never be committed" AuthKey_TEST.p8
  mkdir -p "$REPO/api/.secrets"; echo 'not a key' > "$REPO/api/.secrets/placeholder"
  expect_detected "a tracked .secrets" "the local key directory" api/.secrets/placeholder

  # A scan that did not run has not passed. First a real git failure — an unreadable index —
  # then one `git grep` at a time, so neither exit-status check can cover for the other.
  echo 'not an index' > "$WORK/bad-index"
  run_script GIT_INDEX_FILE="$WORK/bad-index"
  rc=$?
  if [ "$rc" -ne 1 ] || ! grep -qF "git grep exited" "$OUT"; then
    fail "unreadable index: expected exit 1 with \"git grep exited\", got $rc"
  fi
  reset_repo
  expect_grep_error "multi-line PEM scan" '-----BEGIN [A-Z ]*PRIVATE KEY-----'
  expect_grep_error "service-account scan" '"type": *"service_account"'

  return "$FAILS"
}

# expect_grep_error NAME PATTERN — make the git grep for PATTERN alone fail, on a clean tree.
expect_grep_error() {
  local rc
  run_script PATH="$WORK/shim:$PATH" FAIL_GREP_ARG="$2"
  rc=$?
  if [ ! -e "$WORK/shim-fired" ]; then
    fail "$1 error: no git grep was run with that pattern — update the test to match the script"
  elif [ "$rc" -ne 1 ] || ! grep -qF "git grep exited 128" "$OUT"; then
    fail "$1 error: expected exit 1 with \"git grep exited 128\", got $rc"
  fi
  reset_repo
}

# Wipe the repo's history between suites so each starts from its own baseline.
fresh_repo() {
  rm -rf "$REPO/.git"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email test@example.invalid
  git -C "$REPO" config user.name test
  git -C "$REPO" config commit.gpgsign false
}

if [ $# -gt 0 ]; then
  suite "$1"
  n=$?
  [ "$n" -ne 0 ] && { echo "✗ $n case(s) failed"; exit 1; }
  echo "✓ all cases passed"
  exit 0
fi

# Which awk ran matters: CI points `awk` at mawk, and this line is the evidence it did.
echo "awk: $( (awk --version || awk -W version) </dev/null 2>/dev/null | head -1)"
suite "$SUBJECT"
n=$?
if [ "$n" -ne 0 ]; then
  echo "✗ verify-secrets.sh: $n case(s) failed"
  exit 1
fi
echo "✓ verify-secrets.sh: every case"

# ─── Mutants ────────────────────────────────────────────────────────────────────────────
# Each is the script with one safeguard removed. The suite must fail against every one.
# NAME|perl substitution (on the whole file)
MUTANTS=(
  'no -z on git grep|s/git grep -z -lIE/git grep -lIE/'
  'no ./ before awk'"'"'s file|s{"\./\$1" < /dev/null}{"\$1" < /dev/null}'
  'no exit-status check in scan()|s/\*\) scan_failed "\$rc" "\$why" ;;/*) ;;/'
  'no exit-status check on the PEM header scan|s/\*\) scan_failed "\$rc" "\$PEM_WHY" ;;/*) ;;/'
  'the #306 Postmark bracket|s/\(\[Pp\]ostmark\|POSTMARK\)\.\{0,40\}/(postmark|POSTMARK)[^\\n]{0,40}/'
)
MUTANT_FAILS=0
QUIET=1
for m in "${MUTANTS[@]}"; do
  name="${m%%|*}"
  expr="${m#*|}"
  perl -0pe "$expr" "$SUBJECT" > "$WORK/mutant.sh"
  if cmp -s "$SUBJECT" "$WORK/mutant.sh"; then
    echo "✗ mutant \"$name\" no longer applies — the script changed; update the mutation"
    MUTANT_FAILS=1
    continue
  fi
  fresh_repo
  suite "$WORK/mutant.sh"
  n=$?
  if [ "$n" -eq 0 ]; then
    echo "✗ mutant \"$name\": every case still passed — the suite does not guard it"
    MUTANT_FAILS=1
  else
    echo "✓ mutant \"$name\": caught by $n case(s)"
  fi
done
[ "$MUTANT_FAILS" -ne 0 ] && exit 1
echo "✓ verify-secrets.sh test passed"
