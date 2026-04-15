#!/usr/bin/env bash
# Memory stability test: repeatedly fetch an article and verify RSS stabilizes.
# Usage: ./test-memory.sh [ITERATIONS] [URL]
# Set READABILITY_HOST to test against an already-running server (e.g. a Docker container).

set -euo pipefail

for cmd in curl bc; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' is required but not installed" >&2
    exit 1
  fi
done

# JSON field extractor — prefers jq, falls back to node
if command -v jq &>/dev/null; then
  json_field() { jq -r "$1"; }
else
  json_field() {
    local field="$1"
    node -e "
      const d = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
      const keys = '${field}'.replace(/^\./, '').split('.');
      process.stdout.write(String(keys.reduce((o,k) => o[k], d)));
    "
  }
fi

ITERATIONS="${1:-100}"
URL="${2:-https://www.firstpost.com/business/us-iran-oil-waiver-not-renewed-sanctions-economic-fury-india-imports-lukoil-waiver-west-asia-conflict-14000532.html}"
PORT=3000
BASE_URL="${READABILITY_HOST:-http://localhost:$PORT}"
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    echo -e "\nStopping server (pid $SERVER_PID)..."
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "=== Readability Server Memory Test ==="
echo "Iterations: $ITERATIONS"
echo "URL:        $URL"
echo "Server:     $BASE_URL"
echo ""

if [[ -z "${READABILITY_HOST:-}" ]]; then
  echo "Starting server on port $PORT..."
  node src/server.js &
  SERVER_PID=$!
  sleep 2
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "ERROR: Server failed to start"
    exit 1
  fi
fi

BASELINE=$(curl -sf "$BASE_URL/health")
BASELINE_RSS=$(echo "$BASELINE" | json_field '.memory.rssBytes')
BASELINE_HEAP=$(echo "$BASELINE" | json_field '.memory.heapUsedBytes')

to_mb() { echo "scale=2; $1 / 1048576" | bc; }

echo "Baseline  — RSS: $(to_mb "$BASELINE_RSS") MB, Heap: $(to_mb "$BASELINE_HEAP") MB"
echo ""
printf "%-6s  %-12s  %-12s  %-14s  %-14s  %s\n" \
  "#" "RSS (MB)" "Heap (MB)" "RSS Δ base" "Heap Δ base" "Status"
echo "------  ------------  ------------  --------------  --------------  ------"

PREV_RSS=$BASELINE_RSS
PREV_HEAP=$BASELINE_HEAP
FAIL_COUNT=0
HALF=$((ITERATIONS / 2))
HALF_RSS=""

for i in $(seq 1 "$ITERATIONS"); do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "$BASE_URL/" \
    -H 'Content-Type: application/json' \
    -d "{\"url\": \"$URL\"}")

  STATUS="ok"
  if [[ "$HTTP_CODE" != "200" ]]; then
    STATUS="HTTP $HTTP_CODE"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi

  HEALTH=$(curl -sf "$BASE_URL/health")
  RSS=$(echo "$HEALTH" | json_field '.memory.rssBytes')
  HEAP=$(echo "$HEALTH" | json_field '.memory.heapUsedBytes')

  RSS_DELTA=$((RSS - BASELINE_RSS))
  HEAP_DELTA=$((HEAP - BASELINE_HEAP))

  printf "%-6s  %-12s  %-12s  %+13s  %+13s  %s\n" \
    "$i" "$(to_mb "$RSS")" "$(to_mb "$HEAP")" "$(to_mb "$RSS_DELTA")" "$(to_mb "$HEAP_DELTA")" "$STATUS"

  PREV_RSS=$RSS
  PREV_HEAP=$HEAP
  [[ "$i" -eq "$HALF" ]] && HALF_RSS=$RSS

  sleep 0.5
done

echo ""
echo "=== Summary ==="
FINAL_RSS_DELTA=$((PREV_RSS - BASELINE_RSS))
FINAL_HEAP_DELTA=$((PREV_HEAP - BASELINE_HEAP))
echo "Baseline RSS:  $(to_mb "$BASELINE_RSS") MB"
echo "Final RSS:     $(to_mb "$PREV_RSS") MB  ($(to_mb "$FINAL_RSS_DELTA") MB change from baseline)"
echo "Baseline Heap: $(to_mb "$BASELINE_HEAP") MB"
echo "Final Heap:    $(to_mb "$PREV_HEAP") MB  ($(to_mb "$FINAL_HEAP_DELTA") MB change from baseline)"
echo "Failed requests: $FAIL_COUNT / $ITERATIONS"

EXIT_CODE=0

if (( FAIL_COUNT > 0 )); then
  echo ""
  echo "✗  $FAIL_COUNT / $ITERATIONS requests failed"
  EXIT_CODE=1
fi

if [[ -n "$HALF_RSS" ]] && (( ITERATIONS >= 20 )); then
  SECOND_HALF_GROWTH=$((PREV_RSS - HALF_RSS))
  STABILITY_THRESHOLD=52428800  # 50 MB
  echo ""
  echo "Stability check:"
  echo "  RSS at midpoint (iter $HALF): $(to_mb "$HALF_RSS") MB"
  echo "  RSS at end      (iter $ITERATIONS): $(to_mb "$PREV_RSS") MB"
  echo "  Second-half growth: $(to_mb "$SECOND_HALF_GROWTH") MB (threshold: 50 MB)"
  if (( SECOND_HALF_GROWTH > STABILITY_THRESHOLD )); then
    echo "✗  FAIL: RSS grew by more than 50 MB in the second half — memory is not stabilizing"
    EXIT_CODE=1
  else
    echo "✓  PASS: RSS stabilized (second-half growth within 50 MB)"
  fi
fi

exit $EXIT_CODE
