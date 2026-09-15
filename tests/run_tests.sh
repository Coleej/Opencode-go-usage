#!/usr/bin/env bash
# Test suite for opencode-go-usage.sh.
#
# Offline tests run against tests/fixture_server.py. A live test against the
# real API runs too when ~/.local/share/opencode/auth.json exists (skip with
# SKIP_LIVE=1).
#
#   tests/run_tests.sh

set -u
cd "$(dirname "$0")/.."
SCRIPT="$PWD/opencode-go-usage.sh"
PORT="${TEST_PORT:-18741}"
BASE="http://127.0.0.1:$PORT"
T=$(mktemp -d)
SERVER_PID=""

cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT

pass=0
fail=0
check() { # name jq-filter json-file
  local name="$1" filter="$2" file="$3"
  if jq -e "$filter" "$file" >/dev/null 2>&1; then
    echo "PASS  $name"
    pass=$((pass + 1))
  else
    echo "FAIL  $name"
    sed 's/^/      /' "$file"
    fail=$((fail + 1))
  fi
}

# Common env for fixture-backed runs. $1 = cache dir; extra env follows.
fixtenv() {
  local cache="$1"
  shift
  env OPENCODE_GO_CACHE_DIR="$cache" \
    OPENCODE_GO_API_KEY=test-key \
    OPENCODE_GO_USAGE_URL="$BASE/zen/go/v1/usage" \
    OPENCODE_GO_PAGE_URL="$BASE" \
    OPENCODE_GO_SERVER_URL="$BASE/_server" \
    "$@"
}

echo "== syntax =="
bash -n "$SCRIPT" && echo "PASS  bash -n" && pass=$((pass + 1)) || {
  echo "FAIL  bash -n"
  fail=$((fail + 1))
}

python3 tests/fixture_server.py "$PORT" &
SERVER_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -s -o /dev/null --max-time 1 "$BASE/zen/go/v1/usage" && break
  sleep 0.2
done

echo "== usage =="

# 1. fresh fetch against fixture server
fixtenv "$T/c1" "$SCRIPT" >"$T/out1.json"
check "usage fetch" \
  '.ok == true and .error == null and .stale == false
   and .usage.rolling.percent == 12 and .usage.weekly.percent == 34
   and .usage.monthly.percent == 56 and .usage.rolling.resetsAt != null' \
  "$T/out1.json"

# 2. second run within TTL serves the same cache entry
f1=$(jq -r '.fetchedAt' "$T/out1.json")
fixtenv "$T/c1" "$SCRIPT" >"$T/out2.json"
check "cache hit" ".fetchedAt == $f1" "$T/out2.json"

# 3. expired TTL triggers a refetch
C3="$T/c3"
mkdir -p "$C3"
old=$(($(date +%s) - 120)) # older than USAGE_TTL=60, younger than STALE_AGE=300
jq -n --argjson ts "$old" \
  '{"fetchedAt":$ts,"usage":{"rolling":{"status":"ok","percent":99,"resetsAt":"2026-09-14T20:00:00.000Z"}}}' \
  >"$C3/usage.json"
touch -d "@$old" "$C3/usage.json"
fixtenv "$C3" "$SCRIPT" >"$T/out3.json"
check "TTL refetch" ".fetchedAt > $old and .usage.rolling.percent == 12" "$T/out3.json"

# 4. bad key, empty cache -> auth error, no usage
fixtenv "$T/c4" env OPENCODE_GO_API_KEY=bad-key "$SCRIPT" >"$T/out4.json"
check "bad key" \
  '.ok == false and .error == "auth" and .usage == null' \
  "$T/out4.json"
[ -f "$T/c4/backoff_until" ] && echo "PASS  backoff written" && pass=$((pass + 1)) || {
  echo "FAIL  backoff written"
  fail=$((fail + 1))
}

# 5. stale cache retained when refresh fails
C5="$T/c5"
mkdir -p "$C5"
old=$(($(date +%s) - 600))
jq -n --argjson ts "$old" \
  '{"fetchedAt":$ts,"usage":{"rolling":{"status":"ok","percent":99,"resetsAt":"2026-09-14T20:00:00.000Z"}}}' \
  >"$C5/usage.json"
touch -d "@$old" "$C5/usage.json"
fixtenv "$C5" env OPENCODE_GO_API_KEY=bad-key "$SCRIPT" >"$T/out5.json"
check "stale fallback" \
  '.ok == true and .error == "auth" and .stale == true and .usage.rolling.percent == 99' \
  "$T/out5.json"

# 6. no key anywhere -> no_key
mkdir -p "$T/nohome"
env -u OPENCODE_GO_API_KEY HOME="$T/nohome" \
  OPENCODE_GO_CACHE_DIR="$T/c6" \
  OPENCODE_GO_USAGE_URL="$BASE/zen/go/v1/usage" \
  "$SCRIPT" >"$T/out6.json"
check "no key" '.ok == false and .error == "no_key"' "$T/out6.json"

echo "== balance =="

# 7. no cookie -> not_configured
check "balance not_configured" \
  '.balance == null and .balanceError == "not_configured"' \
  "$T/out1.json"

# 8. page scrape (primary path)
fixtenv "$T/c8" env OPENCODE_GO_COOKIE=dummy OPENCODE_GO_WORKSPACE_ID=wrk_page \
  "$SCRIPT" >"$T/out8.json"
check "balance page scrape" \
  '.balance.usd == 42.50 and .balanceError == null' \
  "$T/out8.json"

# 9. billing _server JSON fallback (page has no balance)
fixtenv "$T/c9" env OPENCODE_GO_COOKIE=dummy OPENCODE_GO_WORKSPACE_ID=wrk_billing \
  "$SCRIPT" >"$T/out9.json"
check "balance billing json" \
  '.balance.usd == 42.50 and .balanceError == null' \
  "$T/out9.json"

# 10. billing _server serialized ($R[n]=) fallback
fixtenv "$T/c10" env OPENCODE_GO_COOKIE=dummy OPENCODE_GO_WORKSPACE_ID=wrk_serialized \
  "$SCRIPT" >"$T/out10.json"
check "balance billing serialized" \
  '.balance.usd == 42.50 and .balanceError == null' \
  "$T/out10.json"

# 11. signed-out page -> auth error
fixtenv "$T/c11" env OPENCODE_GO_COOKIE=dummy OPENCODE_GO_WORKSPACE_ID=wrk_signedout \
  "$SCRIPT" >"$T/out11.json"
check "balance signed out" \
  '.balance == null and .balanceError == "auth"' \
  "$T/out11.json"

# 12. redirect (to login) -> auth error
fixtenv "$T/c12" env OPENCODE_GO_COOKIE=dummy OPENCODE_GO_WORKSPACE_ID=wrk_redirect \
  "$SCRIPT" >"$T/out12.json"
check "balance redirect" \
  '.balance == null and .balanceError == "auth"' \
  "$T/out12.json"

# 13. workspace discovery via _server, then page scrape
fixtenv "$T/c13" env OPENCODE_GO_COOKIE=dummy "$SCRIPT" >"$T/out13.json"
check "workspace discovery" \
  '.balance.usd == 42.50 and .balanceError == null' \
  "$T/out13.json"
[ "$(cat "$T/c13/workspace_id" 2>/dev/null)" = "wrk_page" ] &&
  echo "PASS  workspace id cached" && pass=$((pass + 1)) || {
  echo "FAIL  workspace id cached"
  fail=$((fail + 1))
}

# 14. balance cache hit -> same fetchedAt
b1=$(jq -r '.balance.fetchedAt' "$T/out8.json")
fixtenv "$T/c8" env OPENCODE_GO_COOKIE=dummy OPENCODE_GO_WORKSPACE_ID=wrk_page \
  "$SCRIPT" >"$T/out14.json"
check "balance cache hit" ".balance.fetchedAt == $b1" "$T/out14.json"

echo "== live (real API) =="
if [ "${SKIP_LIVE:-0}" != "1" ] && [ -f "$HOME/.local/share/opencode/auth.json" ]; then
  env OPENCODE_GO_CACHE_DIR="$T/live" "$SCRIPT" >"$T/outlive.json"
  check "live fetch" \
    '.ok == true and .error == null and (.usage.rolling.percent | type) == "number"' \
    "$T/outlive.json"
else
  echo "SKIP  live fetch"
fi

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
