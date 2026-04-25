#!/usr/bin/env bash
#
# Run WebContentExtractorIntegrationTests on the iOS Simulator and filter the
# console output for `[Clipper.input]` log lines so we can see exactly what
# WebContentExtractor.extract is doing on each share-attachment shape.
#
# Usage:
#   scripts/test-share-input.sh
#
# Output:
#   Real-time stream of [Clipper.input] log lines as the tests run.
#   A copy is also saved to /tmp/clipper-share-input-log.txt for review.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_FILE="/tmp/clipper-share-input-log.txt"
DESTINATION='platform=iOS Simulator,name=iPhone 17,OS=26.4.1'

echo "============================================================"
echo "Building + running WebContentExtractorIntegrationTests"
echo "Destination: ${DESTINATION}"
echo "Log file:    ${LOG_FILE}"
echo "============================================================"
echo ""

cd "${PROJECT_DIR}"

# Wipe the log file so we get a clean run.
: > "${LOG_FILE}"

# Run xcodebuild test with our integration test class. NSLog output goes to
# stderr; we pipe it through tee so we keep both a live view and an artifact.
# `2>&1` merges stderr into stdout, then `tee` splits it, then `grep` shows
# only the [Clipper.input] lines while the full unfiltered log stays in
# /tmp/clipper-share-input-full.txt.
FULL_LOG="/tmp/clipper-share-input-full.txt"
: > "${FULL_LOG}"

xcodebuild \
  -scheme ObsidianClipper \
  -destination "${DESTINATION}" \
  -only-testing:ObsidianClipperTests/WebContentExtractorIntegrationTests \
  test 2>&1 \
  | tee "${FULL_LOG}" \
  | grep -E '\[Clipper\.input\]|Test Case|Test Suite|FAILED|passed|failed' \
  | tee "${LOG_FILE}"

echo ""
echo "============================================================"
echo "Filtered log: ${LOG_FILE}"
echo "Full log:     ${FULL_LOG}"
echo "============================================================"
