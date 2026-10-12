# GatewayKit
### (Coding Exercise - Podium Interview)

A lightweight, config-driven API gateway in Elixir. Point it at a YAML file and it routes, filters
methods, rate-limits, transforms, retries, breaks circuits, and load-balances accordingly — with
no proxy framework underneath: the proxy logic, the middleware pipeline, the rate limiter, the
breaker, and the balancer are all built here on top of a bare HTTP server, HTTP client, and YAML
parser.

Design notes, trade-offs, and the reasoning behind every ambiguous call live in
[DECISIONS.md](DECISIONS.md).

## Prerequisites

| Tool   | Version                      |
| ------ | ---------------------------- |
| Erlang | 29 (see `.tool-versions`)    |
| Elixir | 1.20 (see `.tool-versions`)  |

With [asdf](https://asdf-vm.com) or [mise](https://mise.jdx.dev): `asdf install` / `mise install`
in the repo root picks both up. Then:

```sh
mix deps.get
```

## Running

The gateway reads its config from a YAML file. The path is resolved in this order:

1. Command-line argument (`mix gateway --config path.yaml` or `mix gateway path.yaml`)
2. `GATEWAY_CONFIG` environment variable
3. `./gateway.yaml`

```sh
mix gateway --config gateway.yaml               # command-line argument
mix gateway gateway.yaml                        # same, positional
GATEWAY_CONFIG=gateway.yaml mix run --no-halt   # environment variable
```

Unknown options or a second path are an error, never a silent fall-back to the default file.

`gateway.yaml` in the repo root is the reference config: five routes on port 8080 exercising every
feature of the schema. To try it without real backends, start echo servers on every upstream port
the config mentions:

```sh
mix upstreams --config gateway.yaml             # echo upstreams on 3001–3006
```

Then, in another terminal:

```sh
curl -s localhost:8080/health                       # {"status":"healthy","uptime_seconds":N}
curl -s localhost:8080/api/users                    # proxied to :3001
curl -s -X DELETE localhost:8080/api/users -i       # 405 + Allow: GET, POST
curl -s localhost:8080/api/nope                     # 404 {"error":"not_found"}
curl -s localhost:8080/api/products/123             # strip_prefix: upstream sees /123
curl -s 'localhost:8080/api/users?page=2'           # query string preserved
```

`GET /health` always answers `200 {"status":"healthy","uptime_seconds":<int>}`, before routing
and regardless of config.

### Other configs

[`examples/`](examples/) holds three more configs that use the same schema:

| File                     | Purpose                                                              |
| ------------------------ | -------------------------------------------------------------------- |
| `examples/minimal.yaml`  | One route, nothing optional — proves every default resolves          |
| `examples/alternate.yaml`| Different ports, paths, and every enum flipped — the schema-generality rehearsal |
| `examples/invalid.yaml`  | Several schema errors — shows the validation report                  |

A malformed config never produces a stacktrace. Every problem is reported at once, then the
process exits non-zero:

```
$ GATEWAY_CONFIG=examples/invalid.yaml mix run --no-halt
Invalid gateway config (examples/invalid.yaml):
  gateway.port                    expected an integer 1..65535, got: 808080
  routes[0].methods               expected a list of methods like ["GET", "POST"], got: "GET"
  routes[1].rate_limit.window     expected a duration like "60s", got: 60
  routes[2].upstream              must have either "url" or "targets"
  routes[3].rate_limit.strategy   expected one of "fixed_window", "sliding_window", got: "token_bucket"
  routes[4].path                  is required
```

Unknown keys are warned about at boot and ignored; unknown enum values are fatal. Quoted numbers
and booleans (`port: "8080"`, `strip_prefix: "true"`) are accepted where the field type makes
them unambiguous.

## Testing

```sh
mix test          # the single test command — no external services, no fixed ports
mix check         # format --check-formatted + credo --strict + test
mix test.html     # HTML coverage report
```

The suite is fully self-contained: every end-to-end test boots a real gateway **and** real mock
upstreams on ephemeral ports (`test/support/`), so it is `async: true` throughout and never
collides with a running dev gateway. Time-based behaviour (rate-limit windows, breaker cooldowns)
is tested with an injectable clock, not `Process.sleep`, and health probes are driven by a
synchronous call rather than the timer.

## Feature checklist

| Feature                                      | Status | Notes                                                  |
| -------------------------------------------- | :----: | ------------------------------------------------------ |
| YAML config from CLI arg or env var          |   ✅   | `--config` → `GATEWAY_CONFIG` → `./gateway.yaml`       |
| Whole-schema validation with a full report   |   ✅   | every error at once; unknown keys warn, bad enums fail |
| `GET /health`                                |   ✅   | always, before routing                                 |
| Prefix routing + `strip_prefix`              |   ✅   | segment-aligned, longest prefix wins                   |
| Method filtering (405 + `Allow`)             |   ✅   |                                                        |
| Proxying with header hygiene                 |   ✅   | hop-by-hop stripped, `Host` rewritten, `X-Forwarded-*` |
| Per-route timeouts (504) / upstream down (502)|  ✅   | `global_timeout` folded into each route                |
| `api_key` auth                               |   ✅   | constant-time compare; missing and wrong key look alike |
| Rate limiting (fixed / sliding window)       |   ✅   | atomic ETS counters; `per: ip` / `global`; 429 + headers |
| Retry with backoff                           |   ✅   | fixed / exponential; never replays after a timeout     |
| Circuit breaker                              |   ✅   | closed → open → half-open; single trial via ETS CAS    |
| Request / response transforms               |   ✅   | headers add/remove, body mapping, envelope, `$vars`    |
| Load balancing (round robin / weighted)      |   ✅   | ring expanded at load; one atomic cursor per route     |
| Active health checks                         |   ✅   | per-route monitor; unhealthy targets skipped; fails closed |

Every feature in the schema is enforced. Known approximations (sliding-window estimation, weight
skew while a target is unhealthy) are listed in [DECISIONS.md §8](DECISIONS.md#8-partially-implemented-features-and-their-current-state).

## Project layout

```
lib/gateway_kit/
├── application.ex        supervision tree; fail-fast config load
├── server.ex             one gateway instance (Bandit + Endpoint)
├── endpoint.ex           the Plug: /health, routing, error rendering
├── router.ex             longest-prefix, segment-aligned matching
├── context.ex            request/response struct that flows through stages
├── stage.ex              the middleware behaviour
├── pipeline.ex           composes enabled stages into one closure per route
├── stage/                one module per feature: auth, rate limit, breaker,
│                         transforms, retry, and the terminal proxy
├── rate_limit/           windowed ETS counters; fixed and sliding strategies
├── breaker.ex            circuit-breaker state machine
├── backoff.ex            retry delays
├── transform/            interpolation, headers, body mapping, envelope
├── upstream/             balancer, target selector, health state and monitor
├── store.ex              supervised owner of all ETS state
└── config/               loader, validator, duration parsing, typed structs
lib/mix/tasks/            mix gateway, mix upstreams
test/support/             mock upstream server, GatewayCase, YAML fixtures
examples/                 alternate, minimal, and invalid configs
```
