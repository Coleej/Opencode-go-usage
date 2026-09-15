#!/usr/bin/env bash
# opencode-go-usage.sh — OpenCode Go usage windows + optional Zen balance.
#
# Prints exactly one JSON line to stdout and exits 0 whenever it can; all
# error state rides in the JSON envelope so callers never parse stderr:
#
#   {"ok":bool,"error":null|"no_key"|"auth"|"fetch"|"parse"|"missing_dep",
#    "fetchedAt":epoch,"stale":bool,
#    "usage":{"rolling":{"status","percent","resetsAt"},"weekly":{...},"monthly":{...}}|null,
#    "balance":{"usd":number,"fetchedAt":epoch}|null,
#    "balanceError":null|"not_configured"|"auth"|"fetch"|"parse"}
#
# Environment:
#   OPENCODE_GO_API_KEY      API key override (default: opencode-go key from
#                            ~/.local/share/opencode/auth.json)
#   OPENCODE_GO_COOKIE       opencode.ai browser cookie header (or bare `auth`
#                            cookie value); enables the Zen balance lookup
#   OPENCODE_GO_WORKSPACE_ID wrk_... — skips workspace auto-discovery
#   OPENCODE_GO_CACHE_DIR    cache dir override (default ~/.cache/opencode-go-usage)
#   OPENCODE_GO_USAGE_URL / OPENCODE_GO_PAGE_URL / OPENCODE_GO_SERVER_URL
#                            endpoint overrides (used by tests)
#
# Args:
#   --force   bypass cache TTL and backoff (user-triggered refresh)

set -u

# --- SolidStart server-function IDs (build hashes) ---------------------------
# The console's _server function IDs are content hashes that can rotate when
# opencode.ai redeploys/restructures the console. If balance or workspace
# discovery starts failing with "parse", lift fresh values from CodexBar:
#   Sources/CodexBarCore/Providers/OpenCodeGo/OpenCodeGoUsageFetcher.swift
#   https://github.com/steipete/CodexBar
WORKSPACES_SERVER_ID="def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f"
BILLING_SERVER_ID="c83b78a614689c38ebee981f9b39a8b377716db85c1fd7dbab604adc02d3313d"

USAGE_URL="${OPENCODE_GO_USAGE_URL:-https://opencode.ai/zen/go/v1/usage}"
PAGE_URL="${OPENCODE_GO_PAGE_URL:-https://opencode.ai}"
SERVER_URL="${OPENCODE_GO_SERVER_URL:-https://opencode.ai/_server}"

CACHE_DIR="${OPENCODE_GO_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/opencode-go-usage}"
USAGE_CACHE="$CACHE_DIR/usage.json"
BALANCE_CACHE="$CACHE_DIR/balance.json"
WS_CACHE="$CACHE_DIR/workspace_id"
LOCK_FILE="$CACHE_DIR/lock"
BACKOFF_FILE="$CACHE_DIR/backoff_until"
ERROR_FILE="$CACHE_DIR/last_error"

USAGE_TTL=60     # seconds a cached usage response is reused
BALANCE_TTL=300  # seconds a cached balance is reused
STALE_AGE=300    # cache older than this renders dimmed in the bar
BACKOFF_SECS=300 # pause between retries after a failed usage fetch

BROWSER_UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

force=0
[ "${1:-}" = "--force" ] && force=1

if ! command -v curl >/dev/null 2>&1 ||
  ! command -v jq >/dev/null 2>&1 ||
  ! command -v flock >/dev/null 2>&1 ||
  ! echo pcre | grep -oP 'pcre' >/dev/null 2>&1; then
  printf '{"ok":false,"error":"missing_dep","fetchedAt":0,"stale":false,"usage":null,"balance":null,"balanceError":null}\n'
  exit 0
fi

mkdir -p "$CACHE_DIR"
now=$(date +%s)

# ---------------------------------------------------------------------------
# API key
# ---------------------------------------------------------------------------
api_key="${OPENCODE_GO_API_KEY:-}"
if [ -z "$api_key" ]; then
  auth_file="$HOME/.local/share/opencode/auth.json"
  if [ -f "$auth_file" ]; then
    api_key=$(jq -r '."opencode-go".key // .opencode.key // empty' "$auth_file" 2>/dev/null)
  fi
fi

# ---------------------------------------------------------------------------
# Usage windows (official API, Bearer-authenticated)
# ---------------------------------------------------------------------------
usage_error=""

maybe_refresh_usage() {
  if [ -z "$api_key" ]; then
    usage_error="no_key"
    return
  fi

  local cache_age=999999 mtime backoff_until=0
  if [ -f "$USAGE_CACHE" ]; then
    mtime=$(stat -c %Y "$USAGE_CACHE" 2>/dev/null || echo 0)
    cache_age=$((now - mtime))
  fi
  [ -f "$BACKOFF_FILE" ] && backoff_until=$(cat "$BACKOFF_FILE" 2>/dev/null || echo 0)
  [ "$force" -eq 0 ] && [ "$cache_age" -lt "$USAGE_TTL" ] && return
  [ "$force" -eq 0 ] && [ "$now" -lt "$backoff_until" ] && return

  # flock: no-op if another bar instance already has a fetch in flight
  (
    flock -n 200 || exit 0
    resp=$(curl -sS --max-time 8 -w $'\n%{http_code}' \
      -H "Authorization: Bearer $api_key" \
      -H "Accept: application/json" \
      "$USAGE_URL" 2>/dev/null) || true
    code="${resp##*$'\n'}"
    body="${resp%$'\n'*}"
    # non-HTTP transports (file:// test fixtures) report 000 with a body
    if [ "$code" = "000" ] && [ -n "$body" ]; then code=200; fi
    case "$code" in
      200)
        if printf '%s' "$body" | jq -e '.usage.rolling | has("percent")' >/dev/null 2>&1; then
          printf '{"fetchedAt":%d,"usage":%s}\n' "$now" \
            "$(printf '%s' "$body" | jq -c '.usage')" >"$USAGE_CACHE.tmp" &&
            mv "$USAGE_CACHE.tmp" "$USAGE_CACHE"
          rm -f "$BACKOFF_FILE" "$ERROR_FILE"
        else
          echo parse >"$ERROR_FILE"
          echo $((now + BACKOFF_SECS)) >"$BACKOFF_FILE"
        fi
        ;;
      401 | 403)
        echo auth >"$ERROR_FILE"
        echo $((now + BACKOFF_SECS)) >"$BACKOFF_FILE"
        ;;
      *)
        echo fetch >"$ERROR_FILE"
        echo $((now + BACKOFF_SECS)) >"$BACKOFF_FILE"
        ;;
    esac
  ) 200>"$LOCK_FILE"

  [ -f "$ERROR_FILE" ] && usage_error=$(cat "$ERROR_FILE" 2>/dev/null)
  return 0
}

maybe_refresh_usage

usage_obj=null
fetched_at=0
if [ -f "$USAGE_CACHE" ]; then
  usage_obj=$(jq -c '.usage // null' "$USAGE_CACHE" 2>/dev/null || echo null)
  fetched_at=$(jq -r '.fetchedAt // 0' "$USAGE_CACHE" 2>/dev/null || echo 0)
fi
case "$usage_obj" in "" | null) usage_obj=null ;; esac
case "$fetched_at" in "" | *[!0-9]*) fetched_at=0 ;; esac

ok=false
[ "$usage_obj" != "null" ] && ok=true
if [ -z "$usage_error" ] && [ "$ok" = "false" ]; then
  usage_error="fetch"
fi

stale=false
if [ "$fetched_at" -gt 0 ] && [ $((now - fetched_at)) -ge "$STALE_AGE" ]; then
  stale=true
fi

# ---------------------------------------------------------------------------
# Zen balance (unofficial console path; only when a cookie is configured)
# ---------------------------------------------------------------------------
cookie="${OPENCODE_GO_COOKIE:-}"
case "$cookie" in
  *=*) ;; # already a full cookie header pair
  *) [ -n "$cookie" ] && cookie="auth=$cookie" ;;
esac

looks_signed_out() {
  printf '%s' "$1" | grep -qiE 'login|sign in|auth/authorize|not associated with an account|actor of type "public"'
}

# GET/POST a SolidStart server function. $1=id $2=args(JSON) $3=referer $4=method
server_call() {
  local sid="$1" args="$2" referer="$3" method="$4"
  local url="$SERVER_URL?id=$sid"
  local uuid
  uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo 00000000-0000-0000-0000-000000000000)
  local curl_args=(
    -sS --max-time 8
    -H "Cookie: $cookie"
    -H "X-Server-Id: $sid"
    -H "X-Server-Instance: server-fn:$uuid"
    -H "User-Agent: $BROWSER_UA"
    -H "Origin: $PAGE_URL"
    -H "Referer: $referer"
    -H "Accept: text/javascript, application/json;q=0.9, */*;q=0.8"
  )
  if [ "$method" = "POST" ]; then
    curl_args+=(-X POST -H "Content-Type: application/json" --data "$args")
  elif [ -n "$args" ]; then
    url="$url&args=$(jq -rn --arg a "$args" '$a | @uri')"
  fi
  curl "${curl_args[@]}" "$url" 2>/dev/null
}

parse_wrk() {
  local text="${1:-}" id=""
  [ -z "$text" ] && return 0
  id=$(printf '%s' "$text" | jq -r '[.. | strings | select(startswith("wrk_"))] | first // empty' 2>/dev/null)
  [ -z "$id" ] && id=$(printf '%s' "$text" | grep -oP 'wrk_[A-Za-z0-9_-]+' | head -n1)
  printf '%s' "$id"
}

# Prints the workspace id, "__auth__" when the cookie is rejected, or "".
discover_workspace() {
  local resp id=""
  resp=$(server_call "$WORKSPACES_SERVER_ID" "" "$PAGE_URL/" GET)
  if looks_signed_out "$resp"; then
    printf '__auth__'
    return
  fi
  id=$(parse_wrk "$resp")
  if [ -z "$id" ]; then
    resp=$(server_call "$WORKSPACES_SERVER_ID" "[]" "$PAGE_URL/" POST)
    if looks_signed_out "$resp"; then
      printf '__auth__'
      return
    fi
    id=$(parse_wrk "$resp")
  fi
  printf '%s' "$id"
}

# Extract a USD amount from the workspace dashboard HTML.
parse_balance_page() {
  local text="$1" v=""
  v=$(printf '%s' "$text" | grep -zoP '(?i)(?:current\s+balance|zen\s+balance)[^$]{0,80}\$\s*\K[0-9][0-9,]*(\.[0-9]+)?' | tr '\0' '\n' | head -n1)
  if [ -z "$v" ]; then
    v=$(printf '%s' "$text" | grep -zoP '(?is)balance.{0,120}?\$\s*\K[0-9][0-9,]*(\.[0-9]+)?' | tr '\0' '\n' | head -n1)
  fi
  printf '%s' "$v" | tr -d ','
}

# Extract the raw balance (dollars * 1e8) from a billing _server response and
# scale it to USD. Handles plain JSON and SolidStart $R[n]= serialized text.
parse_balance_billing() {
  local text="$1" raw=""
  raw=$(printf '%s' "$text" | jq -r '
    [.. | objects
     | select(((.customerID? // "") | length) > 0)
     | (.balance? | if type == "number" then . elif type == "string" then (tonumber? // empty) else empty end)
    ] | first // empty' 2>/dev/null)
  if [ -z "$raw" ] && printf '%s' "$text" | grep -qE '"?customerID"?\s*:\s*(\$R\[[0-9]+\]\s*=\s*)?"[^"]+"'; then
    raw=$(printf '%s' "$text" | grep -oP '"?balance"?\s*:\s*(\$R\[[0-9]+\]\s*=\s*)?\K-?[0-9]+(\.[0-9]+)?' | head -n1)
  fi
  [ -z "$raw" ] && return 0
  awk -v r="$raw" 'BEGIN{ printf "%.2f", r / 100000000 }'
}

fetch_billing() {
  server_call "$BILLING_SERVER_ID" "[\"$1\"]" "$PAGE_URL/workspace/$1" GET
}

refresh_balance() {
  local ws="${OPENCODE_GO_WORKSPACE_ID:-}"
  if [ -z "$ws" ] && [ -f "$WS_CACHE" ]; then
    ws=$(cat "$WS_CACHE" 2>/dev/null)
  fi
  if [ -z "$ws" ]; then
    ws=$(discover_workspace)
    if [ "$ws" = "__auth__" ]; then
      balance_error="auth"
      return
    fi
    [ -n "$ws" ] && printf '%s' "$ws" >"$WS_CACHE"
  fi
  if [ -z "$ws" ]; then
    balance_error="fetch"
    return
  fi

  local resp="" page="" billing="" usd="" transport_ok=0 code=""

  # Primary: scrape the workspace dashboard page (no server-function IDs).
  # No -L: redirect (to login) means an expired cookie, and following
  # cross-host redirects would risk leaking the Cookie header.
  resp=$(curl -sS --max-time 8 -w $'\n%{http_code}' \
    -H "Cookie: $cookie" \
    -H "User-Agent: $BROWSER_UA" \
    -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" \
    "$PAGE_URL/workspace/$ws" 2>/dev/null) || resp=""
  code="${resp##*$'\n'}"
  page="${resp%$'\n'*}"
  if [ "$code" = "000" ] && [ -n "$page" ]; then code=200; fi
  case "$code" in
    301 | 302 | 303 | 307 | 308)
      balance_error="auth"
      return
      ;;
  esac
  if [ -n "$page" ]; then
    transport_ok=1
    if looks_signed_out "$page"; then
      balance_error="auth"
      return
    fi
    usd=$(parse_balance_page "$page")
  fi

  # Fallback: billing server function.
  if [ -z "$usd" ]; then
    billing=$(fetch_billing "$ws")
    if [ -n "$billing" ]; then
      transport_ok=1
      if looks_signed_out "$billing"; then
        balance_error="auth"
        return
      fi
      usd=$(parse_balance_billing "$billing")
    fi
  fi

  case "$usd" in
    "" | *[!0-9.-]*) usd="" ;;
  esac

  if [ -n "$usd" ]; then
    printf '{"fetchedAt":%d,"usd":%s}\n' "$now" "$usd" >"$BALANCE_CACHE.tmp" &&
      mv "$BALANCE_CACHE.tmp" "$BALANCE_CACHE"
    balance_error=""
  elif [ "$transport_ok" -eq 1 ]; then
    balance_error="parse"
  else
    balance_error="fetch"
  fi
}

balance_obj=null
balance_error="not_configured"
if [ -n "$cookie" ]; then
  balance_error=""
  bal_age=999999
  if [ -f "$BALANCE_CACHE" ]; then
    bal_age=$((now - $(stat -c %Y "$BALANCE_CACHE" 2>/dev/null || echo 0)))
  fi
  if [ "$force" -eq 1 ] || [ "$bal_age" -ge "$BALANCE_TTL" ]; then
    refresh_balance
  fi
  if [ -f "$BALANCE_CACHE" ]; then
    balance_obj=$(cat "$BALANCE_CACHE" 2>/dev/null)
    printf '%s' "$balance_obj" | jq -e . >/dev/null 2>&1 || balance_obj=null
  fi
fi

error_json=null
[ -n "$usage_error" ] && error_json=$(jq -cn --arg e "$usage_error" '$e')
balance_error_json=null
[ -n "$balance_error" ] && balance_error_json=$(jq -cn --arg e "$balance_error" '$e')

jq -cn \
  --argjson ok "$ok" \
  --argjson error "$error_json" \
  --argjson fetchedAt "$fetched_at" \
  --argjson stale "$stale" \
  --argjson usage "$usage_obj" \
  --argjson balance "$balance_obj" \
  --argjson balanceError "$balance_error_json" \
  '{ok:$ok, error:$error, fetchedAt:$fetchedAt, stale:$stale, usage:$usage, balance:$balance, balanceError:$balanceError}'
