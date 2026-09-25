#!/bin/bash
# Fail when test-mobile.yml's `push` and `pull_request` path lists differ (#317).
#
#   scripts/verify-mobile-paths.sh [workflow-file]   default: .github/workflows/test-mobile.yml
#
# The two lists are one list written twice, because GitHub Actions rejects YAML anchors. They
# drifted once already: the push list — the one the nightly and main runs use — lacked two
# harness files the PR list had, so a change to either could break the suite on main without
# triggering it. Comments are free to differ; entries and their order are not.
#
# Ruby because its YAML parser is in the standard library on both macOS and the ubuntu runner,
# where PyYAML is not guaranteed. YAML 1.1 reads the bare key `on` as boolean true, hence the
# fallback below. `-Ku -E` because a runner shell may have no UTF-8 locale, and the messages
# carry the same ✓/✗ markers as every other verify script.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILE="${1:-$ROOT/.github/workflows/test-mobile.yml}"

ruby -Ku -EUTF-8:UTF-8 -ryaml -e '
  doc = YAML.load_file(ARGV[0])
  on = doc.key?("on") ? doc["on"] : doc[true]
  pr = on.dig("pull_request", "paths")
  push = on.dig("push", "paths")
  if pr.nil? || push.nil? || pr.empty?
    abort "✗ #{ARGV[0]}: expected non-empty paths under both on.pull_request and on.push"
  end
  if pr == push
    puts "✓ push and pull_request path lists identical (#{pr.length} entries)"
    exit 0
  end
  warn "✗ #{ARGV[0]}: push and pull_request path lists differ (#317)"
  (pr - push).each { |p| warn "  only in pull_request: #{p}" }
  (push - pr).each { |p| warn "  only in push:         #{p}" }
  warn "  same entries, different order" if (pr - push).empty? && (push - pr).empty?
  exit 1
' "$FILE"
