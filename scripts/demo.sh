#!/usr/bin/env bash
#
# GatewayKit live demo.
#
# Boots the echo upstreams and the gateway from gateway.yaml, then walks through the core
# requirements and every configured feature with curl, ending with "what happens when the
# upstreams go down". Run from anywhere inside the repo:
#
#   scripts/demo.sh          # run straight through (~60s)
#   scripts/demo.sh --step   # pause before each section, for presenting
#   scripts/demo.sh --live   # use the upstreams + gateway you already started in other terminals,
#                            # so their output is visible in real time; combine with --step
#
# Live mode expects, in two other terminals:
#
#   mix upstreams --config gateway.yaml
#   mix gateway --config gateway.yaml
#
# and at the "upstreams go down" section it asks you to Ctrl-C the upstreams terminal. Restart the
# gateway between live runs so rate-limit windows and breaker state start fresh.
#
# Needs ports 8080, 8090, 9000, 3001-3006 and 4101-4105 free (in live mode 8080 and 3001-3006 are
# yours). Everything the script itself starts is stopped on exit.

set -uo pipefail
cd "$(dirname "$0")/.."

STEP=0
LIVE=0
for arg in "$@"; do
  case $arg in
    --step) STEP=1 ;;
    --live) LIVE=1 ;;
    *) echo "usage: scripts/demo.sh [--step] [--live]"; exit 2 ;;
  esac
done
LOGS=$(mktemp -d)
PIDS=()
G=http://localhost:8080

cleanup() {
  ((${#PIDS[@]})) && kill "${PIDS[@]}" 2>/dev/null
  wait 2>/dev/null
  printf '\n(logs were in %s)\n' "$LOGS"
}
trap cleanup EXIT

bold() { printf '\033[1m%s\033[0m' "$1"; }
section() {
  printf '\n\033[1;36m══ %s\033[0m\n' "$1"
  if ((STEP)); then read -rp '   [enter] ' _; fi
}
note() { printf '   \033[2m%s\033[0m\n' "$1"; }

# start NAME CMD... — runs CMD in the background, logging to $LOGS/NAME.log; sets LAST_PID
start() {
  local name=$1; shift
  "$@" >"$LOGS/$name.log" 2>&1 &
  LAST_PID=$!
  PIDS+=("$LAST_PID")
}

wait_for() {
  local i
  for i in $(seq 1 160); do
    curl -s "$1" >/dev/null 2>&1 && return 0
    sleep 0.25
  done
  echo "timed out waiting for $1"
  exit 1
}

# require URL WHAT CMD — live mode: fail fast with instructions if something you should have started is not up.
require() {
  local i
  for i in $(seq 1 12); do
    curl -s "$1" >/dev/null 2>&1 && return 0
    sleep 0.25
  done
  printf '\n   ✗ %s is not answering at %s\n     start it in another terminal:  %s\n\n' "$2" "$1" "$3"
  exit 1
}

# wait_down URL — waits (up to 60s) until URL stops answering.
wait_down() {
  local i
  for i in $(seq 1 240); do
    curl -s "$1" >/dev/null 2>&1 || return 0
    sleep 0.25
  done
  echo "   (still answering at $1 — continuing anyway)"
}

# req METHOD URL [curl args...] — prints the command, then the status, interesting headers, and body.
req() {
  local method=$1 url=$2; shift 2
  local headers body status
  headers=$(mktemp)
  printf '\n   $ %s\n' "$(bold "curl -X $method $url $*")"
  body=$(curl -s -X "$method" "$url" -D "$headers" "$@")
  status=$(head -1 "$headers" | awk '{print $2}')
  printf '   → HTTP %s' "$status"
  grep -iE '^(allow|retry-after|x-ratelimit-[a-z]+|x-served-by|x-upstream-port):' "$headers" \
    | tr -d '\r' | sed 's/^/ | /' | tr '\n' ' '
  printf '\n     %s\n' "${body:0:600}"
  rm -f "$headers"
}

# burst N METHOD URL [curl args...] — N requests, printing just the status codes.
burst() {
  local n=$1 method=$2 url=$3; shift 3
  printf '\n   $ %s\n     ' "$(bold "$n × curl -X $method $url $*")"
  local i
  for ((i = 1; i <= n; i++)); do
    printf '%s ' "$(curl -s -o /dev/null -w '%{http_code}' -X "$method" "$url" "$@")"
  done
  echo
}

# ports N URL — N requests, printing which upstream port answered each one.
ports() {
  local n=$1 url=$2
  printf '\n   $ %s\n     ' "$(bold "$n × curl $url   (x-upstream-port)")"
  local i
  for ((i = 1; i <= n; i++)); do
    printf '%s ' "$(curl -s -D - -o /dev/null "$url" | tr -d '\r' | awk 'tolower($1)=="x-upstream-port:"{print $2}')"
  done
  echo
}

# ---------------------------------------------------------------------------------------------

section "Boot — echo upstreams on 3001–3006, gateway on 8080, config from the command line"
if ((LIVE)); then
  note "live mode: using the upstreams and gateway running in your other terminals"
  require http://localhost:3006/healthz "the echo upstreams" "mix upstreams --config gateway.yaml"
  require "$G/health" "the gateway" "mix gateway --config gateway.yaml"
  UPSTREAMS_PID=""
else
  start upstreams mix upstreams --config gateway.yaml
  UPSTREAMS_PID=$LAST_PID
  start gateway mix gateway --config gateway.yaml
  wait_for "$G/health"
  wait_for http://localhost:3006/healthz
  grep -h "Running GatewayKit" "$LOGS/gateway.log" | sed 's/^/   /'
fi
note "path resolution: --config flag (or a bare path) → GATEWAY_CONFIG env var → ./gateway.yaml"

section "Core 2 — GET /health always answers, before routing, regardless of config"
req GET "$G/health"

section "Core 3 — proxying: a matched route is forwarded (the echo shows what the upstream saw)"
req GET "$G/api/users?page=2"
note "query preserved · Host rewritten to the upstream · X-Forwarded-For/Proto/Host added · hop-by-hop headers stripped"
req GET "$G/api/nope"

section "Core 4 — method filtering: a method the route does not allow is 405 with Allow"
req DELETE "$G/api/users"

section "Feature — strip_prefix and weighted round robin (3:1) on /api/products"
req GET "$G/api/products/123"
note "upstream saw /123 (prefix stripped)"
ports 8 "$G/api/products/123"
note "3003 three times, 3004 once: the ring [3003,3003,3003,3004] is expanded at config load, one atomic ETS cursor per route"

section "Feature — rate limiting: /api/orders allows 10 per 10s per client IP (fixed window)"
burst 12 GET "$G/api/orders"
req GET "$G/api/orders"
note "one atomic :ets.update_counter per request — under 50 concurrent requests exactly 10 pass (see the test suite)"

section "Feature — api_key auth on /api/internal (missing and wrong key look identical)"
req GET "$G/api/internal"
req GET "$G/api/internal" -H "X-API-Key: sk_live_abc123"

section "Feature — request and response transforms on /api/legacy"
req POST "$G/api/legacy/v1/data" -H "content-type: application/json" -H "X-Debug: 1" \
  -d '{"userId":"u1","userName":"Ann","extra":"dropped"}'
note "request: path stripped, X-Gateway/X-Request-Start added, X-Debug removed, body restructured to user.{id,name} + meta"
note "response: wrapped in the envelope (data + gateway_metadata), X-Served-By added, Server/X-Powered-By removed"

section "Feature — active health checks (~12s): a dead target is taken out of rotation"
cat >"$LOGS/health.yaml" <<'EOF'
gateway:
  port: 8090
routes:
  - path: "/api/products"
    methods: ["GET"]
    strip_prefix: true
    upstream:
      targets:
        - url: "http://localhost:3003"
          weight: 3
        - url: "http://localhost:3999"   # nothing listens here
          weight: 1
      balance: "weighted_round_robin"
      timeout: "2s"
    health_check:
      path: "/healthz"
      interval: "4s"
      unhealthy_threshold: 2
EOF
note "a second gateway on 8090: targets 3003 (weight 3) and 3999 (nothing listening), probe every 4s, 2 failures → unhealthy"
start health_gateway mix gateway "$LOGS/health.yaml"
wait_for http://localhost:8090/health
burst 8 GET http://localhost:8090/api/products/1
note "before the probes trip: one request in four hits the dead target and gets a 502"
sleep 9
burst 8 GET http://localhost:8090/api/products/1
grep -h "unhealthy" "$LOGS/health_gateway.log" | sed 's/^/   /'
note "if every target were unhealthy the route would fail closed: 503 {\"error\":\"no_healthy_upstream\"}"

section "Core 5 — a different config with the same schema: examples/alternate.yaml on port 9000"
start alt_upstreams mix upstreams --config examples/alternate.yaml
start alt_gateway mix gateway --config examples/alternate.yaml
wait_for http://localhost:9000/health
wait_for http://localhost:4102/healthz
req GET "http://localhost:9000/v2/search/laptops"
req POST "http://localhost:9000/v2/search"
req GET "http://localhost:9000/anything/at/all"
note "different paths, ports, enums (round_robin, fixed backoff, per: global, a different auth header) and a \"/\" catch-all"

section "Core 5 — a malformed config is a readable report and a non-zero exit, never a stacktrace"
printf '   $ %s\n' "$(bold "GATEWAY_CONFIG=examples/invalid.yaml mix run --no-halt")"
GATEWAY_CONFIG=examples/invalid.yaml mix run --no-halt 2>&1 | grep -v "yamerl\|catch\|nowarn\|^%\|^ *│\|^ *┌\|^ *╰\|^$\|Analyzing\|Compiling" | sed 's/^/   /'
echo "   exit code: ${PIPESTATUS[0]}"

section "Production thinking — the upstreams go down"
if ((LIVE)); then
  read -rp "   → press Ctrl-C in the upstreams terminal to stop the echo upstreams, then [enter] here " _
  wait_down http://localhost:3001/healthz
  note "the echo upstreams on 3001–3006 are down"
else
  kill "$UPSTREAMS_PID" 2>/dev/null; wait "$UPSTREAMS_PID" 2>/dev/null
  note "killed the echo upstreams on 3001–3006"
fi
req GET "$G/api/users"
note "/api/orders has retry: attempts 3, exponential 1s → 2s, on connection refused (never on a timeout)"
req GET "$G/api/orders"
if ((LIVE)); then
  note "see the gateway terminal for the two \"Retrying GET /api/orders …\" log lines"
else
  grep -h "Retrying" "$LOGS/gateway.log" | tail -2 | sed 's/^/   /'
fi
note "/api/internal has a circuit breaker: 5 failures within 60s trip it for 30s"
burst 5 GET "$G/api/internal" -H "X-API-Key: sk_live_abc123"
req GET "$G/api/internal" -H "X-API-Key: sk_live_abc123"
note "open → after the cooldown exactly one trial request is let through (atomic ETS compare-and-swap), success closes it"

section "Done — the test suite is the other half of the story:  mix test"
