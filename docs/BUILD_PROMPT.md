# GatewayKit — Build Orchestration Prompt

> **Read this file top to bottom before writing any code.** It is the authoritative spec for this
> build. Where it conflicts with `CLAUDE.md` or `AGENTS.md`, **this file wins** — those were carried
> over from other projects and reference Ecto, Oban, Phoenix, `.env.dist`, and mix aliases that do
> not exist in this repo.

---

## 1. Mission

Build **GatewayKit**: a lightweight, config-driven API gateway in Elixir. It reads a YAML config and
behaves accordingly — routing, method filtering, rate limiting, request/response transformation,
and resilience (timeouts, retries, circuit breaking, load balancing).

**Hard time budget: 2 hours.** The exercise is deliberately larger than fits. Grading is:

| Weight | Category | What it means here |
| --- | --- | --- |
| 35% | Architectural Judgment | *Why* you built what you built, in that order. Extensibility of the pipeline. |
| 25% | Code Quality | Readability, separation of concerns, testing approach. |
| 25% | Production Thinking | Upstream down? Config malformed? 50 concurrent requests on a rate-limited route? |
| 15% | Communication | `DECISIONS.md`, commit history that tells a story, clear `README.md`. |

The graders will run our gateway against the config in §3 **and against a different config file
using the same schema with different values and routes.** Schema-generality is not optional.

### The two rules that govern everything

1. **Core Requirements (§2) must be 100% working before any optional feature is touched.**
2. **Every phase ends at a submittable checkpoint** — formatted, tests green, credo clean, docs
   updated, one commit. If the clock dies mid-phase, the previous checkpoint is a complete,
   coherent submission. Never leave a half-wired feature across a checkpoint boundary.

---

## 2. Core Requirements (non-negotiable baseline)

1. Gateway starts and listens on the configured port (8080 in the sample), reading its config from
   a YAML file path passed as **a CLI argument or an environment variable**.
2. `GET /health` **always** returns `200` with `{"status":"healthy","uptime_seconds":<int>}`,
   regardless of config.
3. **Basic proxying works.** Matching requests are forwarded upstream and the response returned.
   Unmatched routes return `404`.
4. **Method filtering works.** `POST` to a `["GET"]`-only route returns `405`.
5. **Works with any valid config following the schema** — not just the sample.

---

## 3. The spec config — `gateway.yaml`

Write this to the repo root **verbatim** in Phase 0. It is reproduced here exactly so there is zero
transcription risk from the PDF.

```yaml
# gateway.yaml — GatewayKit Configuration

gateway:
  port: 8080
  # Admin/health endpoint is always available at GET /health regardless of config.
  # It should return 200 OK with JSON: { "status": "healthy", "uptime_seconds": <int> }

  global_timeout: "30s"     # Default timeout for all upstream requests
  global_rate_limit:        # Default rate limit applied to all routes unless overridden
    requests: 100
    window: "60s"
    strategy: "fixed_window"  # "fixed_window" or "sliding_window"
    per: "ip"                 # Rate limit bucket key: "ip" or "global"

routes:
  - path: "/api/users"
    methods: ["GET", "POST"]
    strip_prefix: false
    upstream:
      url: "http://localhost:3001"
    rate_limit:
      requests: 30
      window: "60s"
      strategy: "sliding_window"
      per: "ip"

  - path: "/api/orders"
    methods: ["GET", "POST", "PUT"]
    strip_prefix: false
    upstream:
      url: "http://localhost:3002"
      timeout: "5s"           # Override global timeout for this route
    retry:
      attempts: 3
      backoff: "exponential"  # "fixed" or "exponential"
      initial_delay: "1s"
      on: [502, 503, 504]     # HTTP status codes that trigger a retry
    rate_limit:
      requests: 10
      window: "10s"
      strategy: "fixed_window"
      per: "ip"

  - path: "/api/products"
    methods: ["GET"]
    strip_prefix: true        # /api/products/123 -> /123 when forwarded to upstream
    upstream:
      targets:                # Multiple upstream targets for load balancing
        - url: "http://localhost:3003"
          weight: 3
        - url: "http://localhost:3004"
          weight: 1
      balance: "weighted_round_robin"  # "round_robin" or "weighted_round_robin"
      timeout: "10s"
    health_check:
      path: "/healthz"
      interval: "30s"
      unhealthy_threshold: 3  # Mark upstream unhealthy after 3 consecutive failures

  - path: "/api/legacy"
    methods: ["GET", "POST"]
    strip_prefix: true        # /api/legacy/v1/data -> /v1/data when forwarded
    upstream:
      url: "http://localhost:3005"
    request_transform:
      headers:
        add:
          X-Gateway: "gatewaykit"
          X-Request-Start: "$request_time"  # Dynamic value: inject request timestamp
        remove: ["X-Debug", "X-Internal"]
      body:
        # Restructure the request body before forwarding
        # Maps "destination path" <- "source path" using dot notation
        mapping:
          user.id: "userId"
          user.name: "userName"
          meta.source: "$literal:gateway"   # Inject a literal value
          meta.timestamp: "$request_time"
    response_transform:
      headers:
        add:
          X-Served-By: "gatewaykit"
        remove: ["Server", "X-Powered-By"]
      body:
        # Wrap the upstream response in an envelope
        envelope:
          data: "$body"                     # The original response body goes here
          gateway_metadata:
            served_at: "$response_time"
            route: "$route_path"

  - path: "/api/internal"
    methods: ["GET", "POST"]
    strip_prefix: false
    upstream:
      url: "http://localhost:3006"
    auth:
      type: "api_key"
      header: "X-API-Key"
      keys: ["sk_live_abc123", "sk_live_def456"]
    circuit_breaker:
      threshold: 5            # Trip after 5 failures
      window: "60s"           # Within this time window
      cooldown: "30s"         # Wait this long before trying upstream again
      # When tripped, return 503 with:
      # { "error": "service_unavailable", "retry_after": <seconds_remaining> }
```

### ⚠️ YAML 1.1 landmine — verify this in Phase 1

`yaml_elixir` wraps `yamerl`, which implements **YAML 1.1**, where `on`, `off`, `yes`, `no` are
**booleans**. The retry block's `on: [502, 503, 504]` key may come back as the atom/boolean `true`
instead of the string `"on"`.

**First thing after `mix deps.get`, check it:**

```elixir
YamlElixir.read_from_string!(~s(retry:\n  on: [502, 503, 504]\n))
```

If the key is not `"on"`, normalize it in `Config.Validator` (accept `true` as an alias for `"on"`)
and **note it in DECISIONS.md** — it is exactly the kind of real-world parser footgun worth calling
out. Do not silently drop the retry status list.

---

## 4. Library policy — decided, do not re-litigate

The spec permits "your language's standard library HTTP server/client and a YAML parsing library"
and bans "existing API gateway, reverse proxy, or HTTP proxy frameworks/libraries. Building the
proxy logic is the point."

Elixir has no real stdlib HTTP server (only Erlang's 2003-era `:inets`). We read the allowance as
the BEAM-ecosystem equivalent of Go's `net/http`.

**Allowed (add these as direct runtime deps):**

| Dep | Version | Role |
| --- | --- | --- |
| `bandit` | `~> 1.12` | HTTP server (acceptor + HTTP/1.1 + HTTP/2) |
| `plug` | `~> 1.20` | **`Plug.Conn` abstraction + adapter contract only** |
| `finch` | `~> 0.23` | Pooled HTTP client |
| `yaml_elixir` | `~> 2.12` | YAML parsing |
| `jason` | `~> 1.4` | JSON encode/decode |

> `finch`, `jason`, and `mint` already exist in `mix.lock` as **transitive dev/test** deps of
> `usage_rules → igniter → req`. They must be promoted to direct runtime deps — do not assume they
> are available at runtime today.

**Explicitly NOT used. State this list verbatim in `DECISIONS.md`:**

- `ReverseProxyPlug`, `Plug.Proxy` — these *are* the banned thing.
- **`Plug.Router` and `Plug.Builder`** — we hand-write the router and the middleware pipeline.
  Plug is used only as the conn struct and the Bandit adapter contract.
- `Plug.Parsers` — proxying needs raw bytes; parsing is opt-in per-route, by us.
- `:fuse` / `circuit_breaker` — own breaker.
- `hammer` / `ex_rated` / `PlugAttack` — own rate limiter.
- `:retry` — own backoff.
- `Req` — deliberately avoided. Auto-decompression, redirect-following, and built-in retry would
  silently corrupt proxy semantics and quietly duplicate config-driven retry.

**Also: do not run `mix usage_rules.sync`.** It regenerates `.claude/skills/` and trips the
mandatory security-review gate in `AGENTS.md`. Pure time sink here.

---

## 5. Architecture contract

Everything below exists so that **adding a config feature = add one Stage module + one entry in a
list.** The phase ladder in §7 is designed to *demonstrate* that, feature by feature. When you write
`DECISIONS.md`, this is the story.

### 5.1 Request path

```
Client → Bandit → GatewayKit.Endpoint      (a bare @behaviour Plug — no Plug.Router)
  ├─ GET /health  → always, before routing, independent of config
  └─ Router.match(method, path_info)
       ├─ :no_route                     → 404 {"error":"not_found"}
       ├─ {:method_not_allowed, allow}  → 405 + Allow header
       └─ {:ok, route, rest}            → route.pipeline.(Context.new(conn, route))
```

### 5.2 The pipeline — wrapping middleware, composed at config-load time

```elixir
defmodule GatewayKit.Stage do
  @callback enabled?(GatewayKit.Config.Route.t()) :: boolean()
  @callback call(GatewayKit.Context.t(), next) :: GatewayKit.Context.t()
            when next: (GatewayKit.Context.t() -> GatewayKit.Context.t())
end
```

`Pipeline.build/2` folds the stage list right-to-left into a single closure, **omitting disabled
stages entirely at build time**. Consequences worth stating in `DECISIONS.md`:

- A route with no auth pays *literally zero* request-time cost for auth — not a branch, not a nil
  check. The stage isn't in the closure.
- There is **no config interpretation on the hot path**. All of it happens once, at boot.

**Why wrapping instead of a `{:cont, ctx} | {:halt, ctx}` fold:** three stages need both sides of
the call — circuit breaker (check → call → record outcome), retry (loop around the call), response
transform (call → rewrite the result). A one-directional fold cannot express those without leaking
them into the proxy stage.

**Stage order** (outermost first; innermost is the terminal proxy):

```
Auth → RateLimit → CircuitBreaker → RequestTransform → ResponseTransform → Retry → Proxy
```

### 5.3 `%GatewayKit.Context{}`

Carries `route`, `request` (method, path, query, headers, body, client_ip), `response` (status,
headers, body), `started_at`, `halted?`, `assigns`. Stages read and return a Context; only
`Endpoint` knows about `Plug.Conn`.

### 5.4 Module map

| Module | Responsibility | Phase |
| --- | --- | --- |
| `GatewayKit.Application` | supervision tree; fail-fast config load | 0 |
| `GatewayKit.Store` | supervised ETS table owner (see §5.6) | 0 |
| `GatewayKit.Config.Loader` | path resolution (CLI → `GATEWAY_CONFIG` → `./gateway.yaml`), read | 1 |
| `GatewayKit.Config.Validator` | normalize + validate → typed structs, or `{:error, [%Error{path:, message:}]}` | 1 |
| `GatewayKit.Config.Duration` | `"30s"` / `"500ms"` / `"5m"` → ms | 1 |
| `GatewayKit.Config.{Config,Route,Upstream,Target,RateLimit,Retry,CircuitBreaker,Auth,Transform,HealthCheck}` | typed structs | 1 |
| `GatewayKit.Router` | longest-prefix, segment-aligned match; method filter | 1 |
| `GatewayKit.Endpoint` | the Plug: health, routing, error rendering | 1 |
| `GatewayKit.Pipeline` + `GatewayKit.Stage` | composition + behaviour | 1 |
| `GatewayKit.Context` | request/response struct | 1 |
| `GatewayKit.Stage.Proxy` | terminal: header hygiene, path rewrite, Finch call, timeout | 1 |
| `GatewayKit.Upstream.Selector` | target selection (returns `hd(targets)` until Phase 7) | 1 |
| `GatewayKit.Stage.Auth` | `api_key` | 2 |
| `GatewayKit.RateLimit.{Strategy,FixedWindow,SlidingWindow}` + `Stage.RateLimit` | rate limiting | 3 |
| `GatewayKit.Stage.Retry` + `GatewayKit.Backoff` | retry + backoff | 4 |
| `GatewayKit.Stage.CircuitBreaker` + `GatewayKit.Breaker` | breaker state machine | 5 |
| `GatewayKit.Transform.{Interpolate,Headers,BodyMapping,Envelope}` + `Stage.{RequestTransform,ResponseTransform}` | transforms | 6 |
| `GatewayKit.Upstream.Balancer` | `round_robin` / `weighted_round_robin` | 7 |
| `GatewayKit.Upstream.HealthMonitor` | active health checks | 8 (stretch) |

### 5.5 Two rules that protect the "different config file" test

These are the difference between passing and failing the graders' second config. **Do not skip
them.**

1. **The validator understands the entire schema from day one**, including features not yet
   implemented. A config using `targets:`, `health_check:`, `request_transform:` must load cleanly
   in Phase 1. Unimplemented features are **ignored gracefully and logged once at `:info`** —
   *never* fatal, never a crash.
2. **`url:` and `targets:` normalize to the same shape** at load time — always a list of
   `%Target{url:, weight:}`. A bare `url:` becomes a one-element list with `weight: 1`. Phase 1's
   `Selector` returns `hd(targets)`; Phase 7 swaps in the balancer and **nothing else changes**.

### 5.6 Concurrency — the rubric asks about this by name

> *"What happens when 50 requests hit a rate-limited route simultaneously?"*

All shared mutable state lives in ETS owned by a supervised `GatewayKit.Store`, tables created
**unconditionally** in `init/1` (per `docs/development/ELIXIR_CODE_STANDARDS.md` §6.3 — a named
table dies with its owner, so a conditional `:ets.whereis` check is a race, not a safeguard):

```elixir
:ets.new(@rate_limits, [:set, :named_table, :public,
  read_concurrency: true, write_concurrency: true, decentralized_counters: true])
```

Rate-limit counters and round-robin cursors use **atomic `:ets.update_counter/4`**. No GenServer on
the request path, no serialization bottleneck, no lost updates under load. Under 50 concurrent
requests against `requests: 10`, exactly 10 succeed — and there is a test asserting it.

`SlidingWindow` uses the **sliding-window-counter** algorithm (current window count +
time-weighted previous window count) rather than a sliding log: O(1) memory, two atomic
`update_counter` calls, no locks. Document the approximation-vs-exactness tradeoff — a sliding log
is exact but grows with request volume and needs serialization to stay consistent.

**Injectable clock.** `RateLimit` and `Breaker` take `now_ms` as an explicit argument. Tests advance
time by passing it. Per `ELIXIR_CODE_STANDARDS` §4.1 there is **no `Process.sleep`** for window
expiry anywhere in the suite.

### 5.7 Proxy correctness — Phase 1, non-negotiable

This is cheap to get right and is the clearest signal of "real proxy" vs. "HTTP call in a loop":

- **Strip hop-by-hop headers in both directions**: `connection`, `keep-alive`,
  `transfer-encoding`, `upgrade`, `proxy-authenticate`, `proxy-authorization`, `te`, `trailer`.
- Rewrite `Host` to the upstream host.
- Append to `X-Forwarded-For`; set `X-Forwarded-Proto` and `X-Forwarded-Host`.
- Preserve the query string.
- **Recompute `content-length` after any body transform.** Drop `content-encoding` if we altered a
  body we did not decode.
- Read the request body raw (`Plug.Conn.read_body/2`), never `Plug.Parsers`. Decode JSON only when
  a body transform is configured for that route.

### 5.8 Uniform error responses

All gateway-generated errors are JSON with a stable `error` key.

| Status | Body | Notes |
| --- | --- | --- |
| 401 | `{"error":"unauthorized"}` | |
| 404 | `{"error":"not_found"}` | |
| 405 | `{"error":"method_not_allowed"}` | + `Allow` header |
| 429 | `{"error":"rate_limit_exceeded","retry_after":N}` | + `Retry-After`, `X-RateLimit-{Limit,Remaining,Reset}` |
| 502 | `{"error":"bad_gateway"}` | upstream refused / transport error |
| 503 | `{"error":"service_unavailable","retry_after":N}` | breaker open — **exact shape mandated by the spec** |
| 503 | `{"error":"no_healthy_upstream"}` | all targets unhealthy |
| 504 | `{"error":"gateway_timeout"}` | upstream exceeded the route timeout |

---

## 6. Ambiguity decisions — pre-made, do not re-litigate

The spec says ambiguity is intentional: *"Make a call, document your reasoning, and move on."*
These calls are made. Reproduce this table in `DECISIONS.md` with the reasoning column.

| Ambiguity | Call | Reasoning |
| --- | --- | --- |
| Path matching | **Prefix**, segment-aligned. Longest prefix wins. | `strip_prefix: /api/products/123 → /123` proves prefix semantics. `/api/userspace` must **not** match `/api/users` — segment alignment prevents that. |
| `strip_prefix` on an exact path match | Forwards `/` | An empty path is not a valid request target. |
| 404 vs 405 | Match path first; matched path + wrong method → **405 + `Allow`** | RFC 7231 §6.5.5. |
| Stage order | auth → rate limit → breaker → transform → proxy | A bad API key returning 401 regardless of remaining quota is the least surprising behavior; auth is an O(1) list check, so no DoS concern in front of the limiter. |
| Retry + rate limit | Retries consume **no** extra tokens | The client made one request; retries are the gateway's choice, not the client's. |
| `attempts: 3` | **3 total** attempts (1 initial + 2 retries) | The word is "attempts", not "retries". |
| Retry triggers | Configured status codes **plus** connection-refused / connect-timeout | Those never reached the upstream, so replay is safe. |
| Retry on **response** timeout | **No** | The request may have executed. Replaying a `POST` that already created an order is worse than a 504. |
| Timeout scope | **Per attempt**, not a total budget | Matches Envoy/Kong semantics; `timeout` sits on the upstream, alongside the connection. |
| Retry backoff | `exponential` → `initial_delay × 2^n`; `fixed` → constant | Jitter noted as future work — it matters under real fan-out, not here. |
| Breaker failure definition | 5xx + transport errors. **Not** 4xx. | A 404 from upstream is a healthy upstream answering correctly. |
| Breaker states | closed → open → **half-open** (single trial request after cooldown) | The spec only says "wait before trying again"; half-open avoids a thundering herd at cooldown expiry. |
| Breaker scope | Per route | That is where the config sits. |
| `$request_time` / `$response_time` | ISO-8601 UTC via `DateTime.to_iso8601/1` | Self-describing in logs; epoch millis would be ambiguous between s/ms. |
| Body `mapping` | **Whitelist restructure** — only mapped destinations survive | The config comment says "Restructure", not "augment". Unmapped fields are dropped. |
| Body transform on non-JSON | Passthrough, untouched | Never corrupt a body we cannot parse. |
| Response `envelope` | Applied to any parseable body; non-JSON embeds as a string under `data` | |
| `per: "ip"` | `conn.remote_ip` **only** | `X-Forwarded-For` is client-controlled. Honoring it without a trusted-proxy allowlist is a one-header rate-limit bypass. Noted in DECISIONS as a deliberate security call with the config knob we'd add. |
| All targets unhealthy | 503 `no_healthy_upstream` (fail **closed**) | Failing open would hammer a known-dead upstream. |
| `unhealthy_threshold` with no `healthy_threshold` | 1 consecutive success restores healthy | Recover fast, fail slow. |
| Unknown config **keys** | Warn once, continue | Forward-compatibility with the graders' config. |
| Unknown **enum values** (e.g. `strategy: "token_bucket"`) | **Fatal** validation error | Silently falling back to a different limiter is worse than not booting. |

---

## 7. Phase ladder

### Exit criteria for every phase — no exceptions

```sh
mix format
mix test                                    # green
mix credo --strict --min-priority=higher    # clean
```

…then update the `README.md` feature checklist, **append to `DECISIONS.md`**, and make **one
commit**. `DECISIONS.md` is written *incrementally as you go* — never saved for the end, because the
end is where the clock runs out.

Commit messages use conventional-commit prefixes and read as a narrative of the build.

---

### Phase 0 — Foundation · ~10 min

- Commit this file **first**, before any code, so the history opens with plan-then-build.
- Add the five runtime deps (§4). `mix deps.get`. **Immediately run the YAML 1.1 `on:` check
  from §3.**
- `mix.exs`: add `mod: {GatewayKit.Application, []}`, and aliases —
  `f: "format"`, `test.html: "coveralls.html"`, `test.json: "coveralls.json"`,
  `check: ["format --check-formatted", "credo --strict --min-priority=higher", "test"]`.
  (`CLAUDE.md` already documents `mix f` / `mix test.html` / `mix test.json`; this makes those true.)
- `lib/gateway_kit/application.ex` with the supervision tree:

  ```
  GatewayKit.Supervisor (:one_for_one)
  ├─ GatewayKit.Store                       # ETS owner — started first, before any reader
  ├─ {Finch, name: GatewayKit.Finch, pools: …}
  ├─ GatewayKit.Upstream.HealthSupervisor   # DynamicSupervisor (Phase 8; empty until then)
  └─ {Bandit, plug: GatewayKit.Endpoint, port: config.port}
  ```

- Delete the `GatewayKit.hello/0` stub and its test.
- Write `gateway.yaml` verbatim from §3.
- Minimal `config/config.exs` + `config/test.exs` (Logger level only — app config comes from YAML).

**Commit:** `chore: project foundation, runtime deps, and supervision tree`

---

### Phase 1 — Core Requirements ⭐ · ~35 min · **HARD GATE**

Nothing in Phases 2–8 may start until every item in §2 verifiably passes.

**Build:** `Config.{Duration,Loader,Validator}` + structs · `Router` · `Context` · `Stage` +
`Pipeline` · `Endpoint` (health, routing, error rendering) · `Stage.Proxy` (header hygiene,
`strip_prefix`, query preservation, Finch call, per-route timeout → 502/504) ·
`Upstream.Selector` · the `mix gateway` and `mix upstreams` tasks.

**Config failure must be a formatted report on stderr and a non-zero exit — never a stacktrace:**

```
Invalid gateway config (examples/invalid.yaml):
  routes[1].rate_limit.window   expected a duration like "60s", got: 60
  routes[2].upstream            must have either "url" or "targets"
  gateway.port                  expected an integer 1..65535, got: "8080"
```

**Parallel subagent (the only one in this build).** Launch a single `general-purpose` agent at the
start of Phase 1 to build the test harness while the main thread builds the proxy. It is genuinely
independent and otherwise sits on the critical path. Its brief:

> Build `test/support/mock_upstream.ex` — a `Plug` served by Bandit on **port 0 (ephemeral)**,
> startable via `start_supervised!`, returning its bound port. Endpoints: echo (method, path,
> query, headers, body as JSON), canned JSON, slow (configurable delay), flaky (fail N times then
> succeed, counter in the process dict of an Agent), arbitrary-status, and `/healthz`.
> Plus `test/support/gateway_case.ex`, an `ExUnit.CaseTemplate` that boots a real gateway on an
> ephemeral port from a config map with mock-upstream ports templated in, and exposes a Finch
> request helper. Plus the four YAML fixtures in §8. **Do not touch `lib/`.**

**Test:** unit (duration, validator, router) + E2E through a real gateway against real mock
upstreams: 200 proxy, 404, 405 + `Allow`, `/health` shape, `strip_prefix` on/off, query
preservation, upstream-down → 502, upstream-slow → 504, and **all four config fixtures boot**.

**Docs:** `README.md` (setup, run, test, feature checklist, prerequisites) and `DECISIONS.md` v1
(library policy verbatim, the §6 table, prioritization rationale).

**Commits** (four, so the history shows the layering):

```
feat(config): YAML loading, schema validation, and duration parsing
feat(router): prefix routing with method filtering and health endpoint
feat(proxy): upstream forwarding with hop-by-hop header hygiene
test: self-contained mock upstream harness and end-to-end core coverage
docs: README and DECISIONS for the core milestone
```

**→ CHECKPOINT 1. This is a complete, submittable gateway. Verify §9 before continuing.**

---

### Phase 2 — `api_key` auth · ~5 min

The cheapest complete feature in the config, and it exists here to **prove the Stage abstraction**:
~40 lines, one new module, one list entry, zero changes anywhere else. Say exactly that in
`DECISIONS.md` — it is the extensibility argument, demonstrated rather than asserted.

Constant-time key comparison (`Plug.Crypto.secure_compare/2`); missing *and* wrong key both → 401
with an identical body (no oracle). Behaviour-shaped so `bearer`/`jwt` are additive.

**Commit:** `feat(auth): api_key authentication as a pipeline stage`

---

### Phase 3 — Rate limiting · ~15 min

`Strategy` behaviour + `FixedWindow` + `SlidingWindow` (§5.6). `per: "ip" | "global"`. Route config
overrides `global_rate_limit`, resolved at **load time** so routes are fully specified and there is
no runtime fallback branch.

**The test the graders are looking for:** 50 concurrent `Task.async` requests against a
`requests: 10` route → exactly 10 × 200 and 40 × 429. Include it.

**Commit:** `feat(ratelimit): fixed and sliding window strategies with atomic ETS counters`

---

### Phase 4 — Timeouts + retry · ~15 min

Per-route timeout override (wire the config that Phase 1 already parsed). `Backoff` module,
`fixed` / `exponential`. Retry triggers per §6. Tests use the flaky mock upstream — fails twice,
succeeds on attempt 3.

**Commit:** `feat(resilience): per-route timeouts and configurable retry with backoff`

---

### Phase 5 — Circuit breaker · ~10 min

closed → open → half-open, rolling failure window in ETS, `retry_after` computed from remaining
cooldown. Response shape is **mandated by the spec** — match it exactly.

Use **Mimic** here (and only here) if transport-level failures are hard to produce naturally;
otherwise drive it with the mock upstream's arbitrary-status endpoint. Real conditions preferred,
per `AGENTS.md`.

**Commit:** `feat(resilience): per-route circuit breaker with half-open recovery`

---

### Phase 6 — Transforms · ~20 min

`Interpolate` (`$request_time`, `$response_time`, `$route_path`, `$literal:…`, `$body`) as one
module with one clause per variable — adding a variable is a one-line change. `Headers` (add/remove,
case-insensitive). `BodyMapping` (dot-notation, whitelist). `Envelope` (recursive substitution).
Then the two thin stages. **Recompute `content-length`.**

**Commit:** `feat(transform): request and response header and body transformation`

---

### Phase 7 — Load balancing · ~10 min

`round_robin` (atomic cursor) and `weighted_round_robin` (weights expanded into a selection ring at
**config load time**, cursor mod ring length). `Selector` swaps from `hd(targets)` to `Balancer` —
**one line in one module.** Call that out in `DECISIONS.md`; it is rule §5.5.2 paying off.

Test weight distribution: 400 requests against `3:1` → ~300/100.

**Commit:** `feat(lb): round-robin and weighted round-robin target selection`

---

### Phase 8 — Active health checks · stretch, expected to be cut

`HealthMonitor` GenServer per health-checked route under the `DynamicSupervisor`, interval timer,
consecutive-failure threshold, 1 success → healthy, unhealthy targets skipped by the balancer.

**This is the planned cut.** Worst time-to-rubric-value ratio in the config: background timers plus
test flakiness, for a feature the graders cannot easily observe. If the clock is short, **do not
start it** — write the design into `DECISIONS.md` instead. A documented, deliberate omission scores
better than a half-wired GenServer.

**Commit:** `feat(health): active upstream health checking with threshold tracking`

---

### Final · ~10 min — reserve this time, do not let it get eaten

- `DECISIONS.md`: prioritization rationale · architecture + trade-offs · **partially implemented
  features and their exact current state** · what's next with more time (jittered backoff,
  per-consumer rate limit keys, trusted-proxy XFF allowlist, hot config reload via SIGHUP,
  telemetry/structured access logs, streaming bodies for large payloads, HTTP/2 upstreams,
  distributed rate-limit state) · **how AI tools were used** (this file is the evidence — the
  spec explicitly invites it).
- `README.md`: final feature checklist with ✅ / ⚠️ partial / ❌ not built.
- Final `mix check`.

**Commit:** `docs: final decisions, feature checklist, and next steps`

---

## 8. Testing strategy

**Single command: `mix test`.** Fully self-contained — no external services, no fixed ports, no
network.

- **Mock upstreams on port 0**, `start_supervised!` per test. Ephemeral ports mean the suite is
  `async: true`-safe and never collides with a dev gateway on 3001–3006.
- **No `Process.sleep` for time windows** — the clock is injectable (§5.6). `Process.sleep` is
  permitted *only* in the slow-upstream test, where the delay is the thing under test.
- **Mimic only for error injection** (forcing transport failures). Real conditions everywhere else,
  per `AGENTS.md`. `copy` at module level; `expect` in tests, `stub` only in `setup`.
- Layers: unit (validator, duration, router, interpolation, mapping, strategies) → pipeline
  integration → E2E against YAML fixtures.
- Test names per `AGENTS.md`: `describe "GatewayKit.Router.match/2"` with short, behavioral test
  names.

### Config fixtures — our stand-in for the graders' unseen config

| File | Purpose |
| --- | --- |
| `gateway.yaml` (repo root) | The spec config, verbatim (§3) |
| `examples/minimal.yaml` | One route, zero optional features — proves global defaults resolve |
| `examples/alternate.yaml` | **Different ports, paths, and every enum flipped**: `per: "global"`, `backoff: "fixed"`, `balance: "round_robin"`, a different auth header, `strategy` swapped per route. This is the "different config file" rehearsal. |
| `examples/invalid.yaml` | Drives the validation-error report tests |
| `test/support/configs/*.yaml` | Narrow per-feature fixtures |

> `examples/`, not `config/` — `config/` is Mix config.

---

## 9. Running it

Both invocation styles required by Core Requirement 1 are supported:

```sh
GATEWAY_CONFIG=gateway.yaml mix run --no-halt   # environment variable
mix gateway --config gateway.yaml               # command-line argument
mix upstreams --config gateway.yaml             # mock upstreams on the config's ports
mix test                                        # the single test command
mix check                                       # format + credo + test
```

Resolution order: `--config` flag → `GATEWAY_CONFIG` → `./gateway.yaml`.

### Checkpoint 1 smoke test — must all pass before Phase 2

```sh
mix upstreams --config gateway.yaml &
GATEWAY_CONFIG=gateway.yaml mix run --no-halt &

curl -s localhost:8080/health                       # {"status":"healthy","uptime_seconds":N}
curl -s localhost:8080/api/users                    # 200, proxied from :3001
curl -so /dev/null -w '%{http_code}\n' -X DELETE localhost:8080/api/users   # 405 (+ Allow)
curl -so /dev/null -w '%{http_code}\n' localhost:8080/api/nope              # 404
curl -s localhost:8080/api/products/123             # 200, upstream saw /123
curl -s 'localhost:8080/api/users?page=2'           # query string preserved

# schema-generality — this is literally how we will be graded
GATEWAY_CONFIG=examples/alternate.yaml mix run --no-halt
GATEWAY_CONFIG=examples/minimal.yaml   mix run --no-halt
GATEWAY_CONFIG=examples/invalid.yaml   mix run --no-halt   # readable report, exit 1
```

---

## 10. Execution rules

- **Invoke the `elixir-core` skill** before writing Elixir in each phase. Invoke `mimic-framework`
  only in Phase 5.
- **The main thread owns all architecture and every commit.** Exactly one subagent in this build
  (Phase 1 test harness, §7). These modules share too many contracts for wider fan-out — parallel
  agents would each re-derive the pipeline contract and produce interfaces you'd spend the
  remaining time reconciling.
- **Never stage or commit without explicit approval** (`AGENTS.md`), except where the phase-exit
  commits above were pre-authorized at kickoff.
- Follow `docs/development/ELIXIR_CODE_STANDARDS.md`: typespecs on public functions, alphabetized
  aliases, no `String.to_atom/1`, `inspect/1` in Logger interpolation, module attributes for static
  data, and — per the `CLAUDE.md` house rule — **no complex `else` blocks in `with`**; each step
  normalizes its own errors in a private function.
- **If you fall behind: cut the next phase, not the checkpoint discipline.** A clean gateway with
  four features beats a brittle one with seven. That is stated in the spec, and it is how this is
  scored.
