# GatewayKit — walkthrough

A config-driven API gateway in Elixir, built from scratch on an HTTP server (Bandit), an HTTP
client (Finch), and a YAML parser. No proxy frameworks. The YAML file is the spec: it is
validated once into typed structs, every route is compiled into a single closure of enabled
middleware stages at boot, and all shared state is atomic ETS.

| Stack               | Elixir 1.20 / OTP 29 · Bandit · Plug (`Plug.Conn` only) · Finch · yaml_elixir · Jason |
| ------------------- | -------------------------------------------------------------------------------------- |
| Shape               | 18 commits, one per feature · 152 tests in ~2s, fully self-contained                   |
| Reads with          | [README.md](README.md) · [DECISIONS.md](DECISIONS.md) · [gateway.yaml](gateway.yaml)   |

**Agenda (20 min):** 1 · the shape → 2 · the five core requirements, in the code → 3 · the
pipeline, and why it is the extensibility story → 4 · production thinking → 5 · live demo.

---

## 1. The shape of it

```
Client → Bandit → GatewayKit.Endpoint        a bare @behaviour Plug — no Plug.Router
  ├─ GET /health  → always, before routing, independent of config
  └─ Router.match(router, method, path_info)
       ├─ {:error, :not_found}                    → 404 {"error":"not_found"}
       ├─ {:error, {:method_not_allowed, allow}}  → 405 + Allow header
       └─ {:ok, route, suffix}                    → route.pipeline.(Context.new(request, route))

route.pipeline = Auth → RateLimit → CircuitBreaker → RequestTransform → ResponseTransform → Retry → Proxy
                 (only the stages the route configures; composed once at boot)
```

| Layer            | Modules                                                                             |
| ---------------- | ----------------------------------------------------------------------------------- |
| Boot             | [application.ex](lib/gateway_kit/application.ex) · [server.ex](lib/gateway_kit/server.ex) · [cli.ex](lib/gateway_kit/cli.ex) · [mix tasks](lib/mix/tasks/) |
| Config           | [config/loader.ex](lib/gateway_kit/config/loader.ex) · [config/validator.ex](lib/gateway_kit/config/validator.ex) · typed structs in [config/](lib/gateway_kit/config/) |
| Request path     | [endpoint.ex](lib/gateway_kit/endpoint.ex) · [router.ex](lib/gateway_kit/router.ex) · [context.ex](lib/gateway_kit/context.ex) |
| Pipeline         | [stage.ex](lib/gateway_kit/stage.ex) · [pipeline.ex](lib/gateway_kit/pipeline.ex) · one module per feature in [stage/](lib/gateway_kit/stage/) |
| Upstream         | [stage/proxy.ex](lib/gateway_kit/stage/proxy.ex) · [upstream/](lib/gateway_kit/upstream/) (balancer, health) |
| Shared state     | [store.ex](lib/gateway_kit/store.ex) (ETS owner) · [rate_limit/](lib/gateway_kit/rate_limit/) · [breaker.ex](lib/gateway_kit/breaker.ex) |

---

## 2. The five core requirements, in the code

### Req 1 — starts on the configured port, config from a CLI argument or an environment variable

The config is loaded **before** the supervision tree starts. A bad config is a report on stderr
and exit code 1 — never a supervisor crash. → [application.ex](lib/gateway_kit/application.ex)

```elixir
defp load_config! do
  path = Loader.resolve_path()

  case Loader.load(path) do
    {:ok, config} -> config
    {:error, reason} ->
      IO.puts(:stderr, Loader.format_error(path, reason))
      System.halt(1)
  end
end
```

Path resolution, in order: `--config PATH` or a bare `PATH` (parsed by
[cli.ex](lib/gateway_kit/cli.ex), unknown options are an error) → `GATEWAY_CONFIG` → `./gateway.yaml`.
→ [config/loader.ex](lib/gateway_kit/config/loader.ex)

```elixir
def resolve_path(opts \\ []) do
  opts[:path] || Application.get_env(:gateway_kit, :config_path) || System.get_env(@env_var) || @default_path
end
```

```sh
mix gateway --config gateway.yaml               # or:  mix gateway gateway.yaml
GATEWAY_CONFIG=gateway.yaml mix run --no-halt
```

Tree: `Store` (ETS owner, first) → Finch pool → `Server` (a `Supervisor`: one health monitor per
health-checked route + the Bandit listener). Config is passed as plug options, not global state,
so many instances can run in one VM — every test boots its own on port 0.

### Req 2 — `GET /health` always answers, regardless of config

The first `call/2` clause pattern-matches the health request before routing happens, so it works
with any config, including one with no routes or one that defines its own `/health`.
→ [endpoint.ex](lib/gateway_kit/endpoint.ex)

```elixir
def call(%Plug.Conn{method: "GET", path_info: ["health"]} = conn, %{started_at: started_at}) do
  uptime = System.monotonic_time(:second) - started_at
  send_json(conn, 200, %{status: "healthy", uptime_seconds: uptime})
end
```

`started_at` comes from `init/1`, which Bandit calls once at startup — the same place every
route's pipeline is compiled.

### Req 3 — proxying works; unmatched routes are 404

Routing is longest-prefix and **segment-aligned**: `/api/users` matches `/api/users/42` but never
`/api/userspace`. → [router.ex](lib/gateway_kit/router.ex)

```elixir
def match(%__MODULE__{routes: routes}, method, path_info) do
  case Enum.filter(routes, &List.starts_with?(path_info, &1.segments)) do
    [] -> {:error, :not_found}
    [%Route{segments: segments} | _rest] = candidates ->
      match_longest(candidates, length(segments), method, path_info)
  end
end
```

The endpoint reads the body raw (`Plug.Conn.read_body/2` in a loop, never `Plug.Parsers`), runs
the route's closure, and writes the response back. It is the only module that touches `Plug.Conn`.

```elixir
{:ok, route, _suffix} -> dispatch(conn, route)
{:error, :not_found} -> send_json(conn, 404, %{error: "not_found"})
```

The terminal stage forwards with Finch, per-route timeout per attempt.
→ [stage/proxy.ex](lib/gateway_kit/stage/proxy.ex)

```elixir
defp forward(%Context{route: route, request: request} = ctx, %Target{} = target) do
  timeout = route.upstream.timeout_ms

  request.method
  |> Finch.build(upstream_url(target, route, request), upstream_headers(request, target), upstream_body(request))
  |> send_request(timeout)
  |> handle_result(ctx)
end
```

Proxy hygiene, the difference between a proxy and "an HTTP call in a loop":

- hop-by-hop headers stripped in both directions (`connection`, `keep-alive`, `transfer-encoding`,
  `upgrade`, `te`, `trailer`, … plus anything named in `Connection`)
- `Host` rewritten to the upstream; `X-Forwarded-For` appended, `X-Forwarded-Proto/Host` set
- query string preserved; `Content-Length` dropped so the client recomputes it after transforms
- `strip_prefix` applied from the raw path, so percent-encoding survives (`/a%20b` stays `/a%20b`)
- timeout → `504 gateway_timeout`; refused / DNS / pool exhaustion → `502 bad_gateway`

### Req 4 — method filtering returns 405

The **longest** matching prefix decides. Among routes of that length the first that accepts the
method wins (so one path may be split by method); if none do, it is a 405 carrying an `Allow`
header — a shorter route is never consulted for a method the longer one rejects.

```elixir
defp match_longest(candidates, depth, method, path_info) do
  longest = Enum.take_while(candidates, &(length(&1.segments) == depth))

  case Enum.find(longest, &(method in &1.methods)) do
    %Route{} = route -> {:ok, route, Enum.drop(path_info, depth)}
    nil -> {:error, {:method_not_allowed, allowed_methods(longest)}}
  end
end
```

```elixir
{:error, {:method_not_allowed, allowed}} ->
  conn
  |> put_resp_header("allow", Enum.join(allowed, ", "))
  |> send_json(405, %{error: "method_not_allowed"})
```

### Req 5 — works with any valid config of the schema

The validator understands the **whole schema** and normalizes everything once, at load time, so
nothing on the request path interprets config. → [config/validator.ex](lib/gateway_kit/config/validator.ex)

- **Every error is collected**, not just the first — field parsers return
  `{:ok, value} | {:error, [Error]}` and a small combinator gathers them:

  ```elixir
  defp collect(fields) do
    Enum.reduce(fields, {:ok, %{}}, fn
      {key, {:ok, value}}, {:ok, acc} -> {:ok, Map.put(acc, key, value)}
      {_key, {:ok, _value}}, {:error, _} = errors -> errors
      {_key, {:error, errors}}, {:ok, _acc} -> {:error, errors}
      {_key, {:error, errors}}, {:error, acc} -> {:error, acc ++ errors}
    end)
  end
  ```

- **Unknown keys warn; unknown enum values fail.** A typo'd key is forward-compatible noise;
  `strategy: "token_bucket"` silently becoming a different limiter would be worse than not booting.
- **Normalized at load:** `global_timeout` / `global_rate_limit` folded into every route;
  `url:` and `targets:` become one list of targets plus a pre-expanded weighted ring; durations
  → ms; header names lowercased; `$variables` parsed; quoted numbers and booleans accepted.
- Proven against configs that are not the sample: [examples/minimal.yaml](examples/minimal.yaml)
  (nothing optional), [examples/alternate.yaml](examples/alternate.yaml) (different ports, paths,
  every enum flipped, a `/` catch-all), and seven per-feature fixtures under
  [test/support/configs/](test/support/configs/).

```
$ GATEWAY_CONFIG=examples/invalid.yaml mix run --no-halt
Invalid gateway config (examples/invalid.yaml):
  gateway.port                    expected an integer 1..65535, got: 808080
  routes[0].methods               expected a list of methods like ["GET", "POST"], got: "GET"
  routes[1].rate_limit.window     expected a duration like "60s", got: 60
  routes[2].upstream              must have either "url" or "targets"
  routes[3].rate_limit.strategy   expected one of "fixed_window", "sliding_window", got: "token_bucket"
  routes[4].path                  is required
$ echo $?
1
```

---

## 3. The pipeline — why adding a feature is one module and one list entry

A stage is **wrapping** middleware: it receives the context and the rest of the pipeline, and
decides whether and when to call it. That is what lets one stage act on both sides of the
upstream call — the breaker checks before and records after; retry loops around it; the response
transform rewrites what came back. → [stage.ex](lib/gateway_kit/stage.ex)

```elixir
@callback enabled?(Route.t()) :: boolean()
@callback call(Context.t(), next()) :: Context.t()
```

`enabled?/1` is evaluated once, at boot. Disabled stages are left out of the closure entirely — a
route without auth has no auth code in its path, not a branch, not a nil check.
→ [pipeline.ex](lib/gateway_kit/pipeline.ex)

```elixir
@stages [
  GatewayKit.Stage.Auth,
  GatewayKit.Stage.RateLimit,
  GatewayKit.Stage.CircuitBreaker,
  GatewayKit.Stage.RequestTransform,
  GatewayKit.Stage.ResponseTransform,
  GatewayKit.Stage.Retry,
  GatewayKit.Stage.Proxy
]

def build(%Route{} = route, stages \\ @stages) do
  stages
  |> Enum.filter(& &1.enabled?(route))
  |> List.foldr(&Function.identity/1, fn stage, next -> &stage.call(&1, next) end)
end
```

Auth was built first to prove it — one module, one list entry, nothing else changed.
→ [stage/auth.ex](lib/gateway_kit/stage/auth.ex)

```elixir
def enabled?(%Route{auth: %Auth{}}), do: true
def enabled?(%Route{auth: nil}), do: false

def call(%Context{route: %Route{auth: auth}, request: request} = ctx, next) do
  if authorized?(auth, request.headers) do
    next.(ctx)
  else
    Context.halt(ctx, 401, %{error: "unauthorized"})
  end
end
```

The rest of the schema landed the same way, in this order (each one commit, each green):
auth → rate limiting → timeouts and retry → circuit breaker → transforms → load balancing →
health checks. See `git log --oneline`.

---

## 4. Production thinking

**50 requests hit a rate-limited route at once → exactly 10 succeed.** Each request is one atomic
`:ets.update_counter/4`; the decision uses the count *including its own increment*, so there is
no read-then-write window. No process sits on the request path.
→ [rate_limit/window.ex](lib/gateway_kit/rate_limit/window.ex) · [rate_limit/fixed_window.ex](lib/gateway_kit/rate_limit/fixed_window.ex)

```elixir
def increment(table, key, index, window_ms) do
  expires_at = (index + 2) * window_ms
  :ets.update_counter(table, {key, index}, {2, 1}, {{key, index}, 0, expires_at})
end
```

```elixir
count = Window.increment(table, key, index, window_ms)
if count <= limit, do: {:allow, info}, else: {:deny, info}
```

Verified twice: 50 concurrent tasks with a fixed clock, and 50 concurrent HTTP requests through a
real gateway (`%{200 => 10, 429 => 40}`). The sliding window is the sliding-window *counter*
(`previous × (1 − elapsed) + current`): O(1) memory and lock-free, at the cost of a bounded
approximation.

**An upstream is down.** 502 immediately. With `retry:`, a request is replayed only when it
provably never reached the upstream — **never after a timeout**, because a duplicated
`POST /orders` is worse than a 504. → [stage/retry.ex](lib/gateway_kit/stage/retry.ex)

```elixir
defp retryable?(%Context{halted?: false, response: %Response{status: status}}, %Retry{on: statuses}) do
  status in statuses
end

defp retryable?(%Context{halted?: true, error: error}, _retry), do: error in @replayable
```

**An upstream keeps failing.** The circuit breaker is a per-route state machine in ETS
(closed → open → half-open). At cooldown expiry, exactly **one** request becomes the trial: the
transition is an atomic compare-and-swap, so 50 waiting clients do not stampede a recovering
upstream. Failures are 5xx and transport errors only — a 4xx is a healthy upstream answering.
→ [breaker.ex](lib/gateway_kit/breaker.ex)

```elixir
defp claim_trial(route_id, state, since, now_ms) do
  spec = [{{route_id, state, since}, [], [{{route_id, :half_open, now_ms}}]}]

  case :ets.select_replace(Store.breakers(), spec) do
    1 -> :allow
    0 -> {:reject, 0}
  end
end
```

**A target is dead.** A `GenServer` per health-checked route probes each target on the configured
interval; `unhealthy_threshold` consecutive failures take it out of rotation, one success brings
it back. All targets dead → fail **closed**, `503 no_healthy_upstream`.
→ [upstream/health_monitor.ex](lib/gateway_kit/upstream/health_monitor.ex) · [upstream/balancer.ex](lib/gateway_kit/upstream/balancer.ex)

**Every gateway error has one shape:**

| Status | Body                                                  | When                                |
| ------ | ----------------------------------------------------- | ----------------------------------- |
| 401    | `{"error":"unauthorized"}`                            | missing or wrong key (identical)    |
| 404    | `{"error":"not_found"}`                               | no route                            |
| 405    | `{"error":"method_not_allowed"}` + `Allow`            | route rejects the method            |
| 429    | `{"error":"rate_limit_exceeded","retry_after":N}` + `Retry-After`, `X-RateLimit-*` | quota exhausted |
| 502    | `{"error":"bad_gateway"}`                             | upstream refused / transport error  |
| 503    | `{"error":"service_unavailable","retry_after":N}`     | breaker open (shape from the spec)  |
| 503    | `{"error":"no_healthy_upstream"}`                     | every target unhealthy              |
| 504    | `{"error":"gateway_timeout"}`                         | route timeout exceeded              |

**Tests are the other half.** `mix test` — 152 tests, every end-to-end test boots a real gateway
and real mock upstreams on ephemeral ports ([test/support/](test/support/)), time is an
injectable `now_ms` (no sleeping for windows or cooldowns), and health probes are driven by a
synchronous call instead of the timer.

---

## 5. Decisions worth knowing (all in [DECISIONS.md](DECISIONS.md))

- Core requirements first as a hard gate; optional features in order of value ÷ cost; every phase
  a green, formatted, linted commit. §1
- `X-Forwarded-For` is ignored for `per: "ip"` — it is client-controlled, and honouring it without
  a trusted-proxy allowlist is a one-header bypass. §4
- Retries consume no rate-limit quota and count once against the breaker. §4
- Health checks were the planned cut and were re-landed after a requirements gut check showed
  one in four `/api/products` requests would fail with a target down on the sample config. §7
- Next with more time: jittered backoff, trusted proxies, per-consumer rate-limit keys, hot
  reload, telemetry, streaming bodies, distributed rate-limit state. §9
- AI: a written plan fixed the architecture before any code; the human made the scope calls. §10

---

## 6. Live demo

```sh
mix upstreams --config gateway.yaml     # terminal 1 — echo servers on the config's upstream ports
mix gateway --config gateway.yaml       # terminal 2 — the gateway, log visible
scripts/demo.sh --live --step           # terminal 3 — walks each requirement with curl
mix test                                # the single command for the suite
```

(`scripts/demo.sh --step` alone starts and stops everything itself.)

What the script shows, in order: boot on 8080 from the CLI · `/health` · proxy + 404 ·
405 + `Allow` · `strip_prefix` and the 3:1 balance · 10-then-429 with headers · auth ·
transforms · a dead target leaving rotation · the alternate config on 9000 · the invalid-config
report · and finally the upstreams going down: 502, retry backoff in the log, and the breaker
tripping to the mandated 503.
