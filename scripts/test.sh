#!/usr/bin/env bash
# Runs the unit tests. Usage: scripts/test.sh [TestClassOrSuite]
set -uo pipefail
cd "$(dirname "$0")/.."
xcodegen -q
LOG=.superpowers/last-test.log; mkdir -p .superpowers
ARGS=(-scheme Sidekick -destination 'platform=macOS' test)
[ $# -gt 0 ] && ARGS+=(-only-testing:"SidekickTests/$1")
xcodebuild "${ARGS[@]}" > "$LOG" 2>&1; rc=$?
grep -E "error:|✘|Test run with|\*\* TEST" "$LOG" | grep -v linkd | tail -25
exit $rc
