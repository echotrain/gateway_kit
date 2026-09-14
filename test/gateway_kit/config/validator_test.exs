defmodule GatewayKit.Config.ValidatorTest do
  use ExUnit.Case, async: true

  alias GatewayKit.Config

  alias GatewayKit.Config.{
    Auth,
    CircuitBreaker,
    Error,
    HealthCheck,
    RateLimit,
    Retry,
    Route,
    Target,
    Transform,
    Upstream,
    Validator
  }

  @all_methods ~w(GET HEAD POST PUT PATCH DELETE OPTIONS TRACE CONNECT)

  defp raw_config(routes, gateway \\ %{"port" => 8080}) do
    %{"gateway" => gateway, "routes" => routes}
  end

  defp raw_route(overrides \\ %{}) do
    Map.merge(%{"path" => "/api", "upstream" => %{"url" => "http://localhost:4000"}}, overrides)
  end

  defp errors(raw) do
    assert {:error, errors} = Validator.validate(raw)
    Map.new(errors, fn %Error{path: path, message: message} -> {path, message} end)
  end

  describe "GatewayKit.Config.Validator.validate/1 with the spec config" do
    setup do
      {:ok, config} = "gateway.yaml" |> File.read!() |> YamlElixir.read_from_string!() |> Validator.validate()
      %{config: config, routes: Map.new(config.routes, &{&1.path, &1})}
    end

    test "loads every route with no warnings", %{config: config} do
      assert %Config{port: 8080, global_timeout_ms: 30_000, warnings: []} = config
      assert Enum.map(config.routes, & &1.path) == ~w(/api/users /api/orders /api/products /api/legacy /api/internal)
      assert config.routes |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 5
    end

    test "folds global timeout and rate limit into routes that do not override them", %{routes: routes} do
      assert %Route{upstream: %Upstream{timeout_ms: 30_000}, rate_limit: %RateLimit{requests: 100, window_ms: 60_000}} =
               routes["/api/legacy"]

      assert %Route{upstream: %Upstream{timeout_ms: 5_000}, rate_limit: %RateLimit{requests: 10, window_ms: 10_000}} =
               routes["/api/orders"]

      assert %RateLimit{strategy: :sliding_window, per: :ip} = routes["/api/users"].rate_limit
    end

    test "normalizes a bare url and a targets list to the same shape", %{routes: routes} do
      assert %Upstream{targets: [%Target{url: "http://localhost:3001", weight: 1}], balance: :round_robin} =
               routes["/api/users"].upstream

      assert %Upstream{balance: :weighted_round_robin, targets: [%Target{weight: 3}, %Target{weight: 1}]} =
               routes["/api/products"].upstream

      assert %URI{scheme: "http", host: "localhost", port: 3001, path: ""} =
               hd(routes["/api/users"].upstream.targets).uri
    end

    test "expands weights into a selection ring at load time", %{routes: routes} do
      ring = routes["/api/products"].upstream.ring

      assert ring |> Tuple.to_list() |> Enum.map(& &1.url) ==
               ["http://localhost:3003", "http://localhost:3003", "http://localhost:3003", "http://localhost:3004"]

      assert tuple_size(routes["/api/users"].upstream.ring) == 1
    end

    test "parses retry, breaker, auth, and health check blocks", %{routes: routes} do
      assert %Retry{attempts: 3, backoff: :exponential, initial_delay_ms: 1_000, on: [502, 503, 504]} =
               routes["/api/orders"].retry

      assert %CircuitBreaker{threshold: 5, window_ms: 60_000, cooldown_ms: 30_000} =
               routes["/api/internal"].circuit_breaker

      assert %Auth{type: :api_key, header: "x-api-key", keys: ["sk_live_abc123", "sk_live_def456"]} =
               routes["/api/internal"].auth

      assert %HealthCheck{path: "/healthz", interval_ms: 30_000, unhealthy_threshold: 3} =
               routes["/api/products"].health_check
    end

    test "pre-parses transforms with lowercased header names and typed values", %{routes: routes} do
      %Route{request_transform: request, response_transform: response} = routes["/api/legacy"]

      assert %Transform{
               add_headers: [{"x-gateway", {:literal, "gatewaykit"}}, {"x-request-start", {:var, "$request_time"}}],
               remove_headers: ["x-debug", "x-internal"],
               body: {:mapping, mapping}
             } = request

      assert Enum.sort(mapping) == [
               {["meta", "source"], {:literal, "gateway"}},
               {["meta", "timestamp"], {:var, "$request_time"}},
               {["user", "id"], {:path, ["userId"]}},
               {["user", "name"], {:path, ["userName"]}}
             ]

      assert %Transform{
               add_headers: [{"x-served-by", {:literal, "gatewaykit"}}],
               remove_headers: ["server", "x-powered-by"],
               body: {:envelope, envelope}
             } = response

      assert envelope == %{
               "data" => {:var, "$body"},
               "gateway_metadata" => %{"route" => {:var, "$route_path"}, "served_at" => {:var, "$response_time"}}
             }
    end
  end

  describe "GatewayKit.Config.Validator.validate/1 defaults" do
    test "a minimal route resolves every optional field" do
      assert {:ok, %Config{routes: [route]}} = Validator.validate(raw_config([raw_route()]))

      assert %Route{
               path: "/api",
               segments: ["api"],
               methods: @all_methods,
               strip_prefix: false,
               upstream: %Upstream{timeout_ms: 30_000, balance: :round_robin},
               rate_limit: nil,
               retry: nil,
               circuit_breaker: nil,
               auth: nil,
               request_transform: nil,
               response_transform: nil,
               health_check: nil,
               pipeline: nil
             } = route
    end

    test "missing routes means a health-only gateway" do
      assert {:ok, %Config{routes: []}} = Validator.validate(%{"gateway" => %{"port" => 1}})
    end

    test "methods are upcased and de-duplicated" do
      assert {:ok, %Config{routes: [%Route{methods: ["GET", "POST"]}]}} =
               Validator.validate(raw_config([raw_route(%{"methods" => ["get", "Post", "GET"]})]))
    end

    test "optional block keys fall back to documented defaults" do
      route =
        raw_route(%{
          "retry" => %{"attempts" => 2},
          "circuit_breaker" => %{"threshold" => 4},
          "health_check" => %{"path" => "/ping"},
          "rate_limit" => %{"requests" => 5, "window" => "1s"}
        })

      assert {:ok, %Config{routes: [route]}} = Validator.validate(raw_config([route]))
      assert %Retry{attempts: 2, backoff: :exponential, initial_delay_ms: 100, on: [502, 503, 504]} = route.retry
      assert %CircuitBreaker{threshold: 4, window_ms: 60_000, cooldown_ms: 30_000} = route.circuit_breaker
      assert %HealthCheck{path: "/ping", interval_ms: 30_000, unhealthy_threshold: 3} = route.health_check
      assert %RateLimit{requests: 5, window_ms: 1_000, strategy: :fixed_window, per: :ip} = route.rate_limit
    end

    test "the retry status list survives YAML parsing of the 'on' key" do
      yaml =
        "gateway:\n  port: 1\nroutes:\n  - path: /a\n    upstream:\n      url: http://h:1\n    retry:\n      attempts: 2\n      on: [502, 503]\n"

      assert {:ok, %Config{routes: [%Route{retry: %Retry{on: [502, 503]}}]}} =
               yaml |> YamlElixir.read_from_string!() |> Validator.validate()
    end
  end

  describe "GatewayKit.Config.Validator.validate/1 errors" do
    test "reports every problem across sections in config order" do
      raw = %{
        "gateway" => %{"port" => "eighty"},
        "routes" => [
          %{"path" => "/a", "upstream" => %{}, "rate_limit" => %{"requests" => 1, "window" => 60}},
          %{"path" => "/b", "methods" => "GET", "upstream" => %{"url" => "http://x:1"}},
          %{"upstream" => %{"url" => "http://x:1"}}
        ]
      }

      assert {:error, errors} = Validator.validate(raw)

      assert Enum.map(errors, & &1.path) == [
               "gateway.port",
               "routes[0].upstream",
               "routes[0].rate_limit.window",
               "routes[1].methods",
               "routes[2].path"
             ]

      assert hd(errors).message == ~s(expected an integer 1..65535, got: "eighty")
    end

    test "quoted integers and booleans are accepted where the type is unambiguous" do
      route =
        raw_route(%{
          "strip_prefix" => "true",
          "upstream" => %{"targets" => [%{"url" => "http://h:1", "weight" => "3"}]},
          "retry" => %{"attempts" => "2", "on" => ["503", 502]},
          "rate_limit" => %{"requests" => "10", "window" => "1s"},
          "auth" => %{"type" => "api_key", "header" => "X-Key", "keys" => ["12345"]}
        })

      assert {:ok, %Config{port: 8080, routes: [route]}} = Validator.validate(raw_config([route], %{"port" => "8080"}))
      assert route.strip_prefix == true
      assert [%Target{weight: 3}] = route.upstream.targets
      assert %Retry{attempts: 2, on: [503, 502]} = route.retry
      assert %RateLimit{requests: 10} = route.rate_limit
      assert %Auth{keys: ["12345"]} = route.auth
    end

    test "strings that are not numbers or booleans are still rejected, showing the original value" do
      errors = errors(raw_config([raw_route(%{"strip_prefix" => "yes"})], %{"port" => "eighty"}))

      assert errors["gateway.port"] == ~s(expected an integer 1..65535, got: "eighty")
      assert errors["routes[0].strip_prefix"] == ~s(expected true or false, got: "yes")
    end

    test "unknown enum values are fatal" do
      route =
        raw_route(%{
          "rate_limit" => %{"requests" => 1, "window" => "1s", "strategy" => "token_bucket", "per" => "user"},
          "retry" => %{"attempts" => 1, "backoff" => "linear"},
          "auth" => %{"type" => "jwt", "header" => "x", "keys" => ["k"]},
          "upstream" => %{"url" => "http://h:1", "balance" => "least_conn"}
        })

      errors = errors(raw_config([route]))

      assert errors["routes[0].rate_limit.strategy"] ==
               ~s(expected one of "fixed_window", "sliding_window", got: "token_bucket")

      assert errors["routes[0].rate_limit.per"] == ~s(expected one of "global", "ip", got: "user")
      assert errors["routes[0].retry.backoff"] == ~s(expected one of "exponential", "fixed", got: "linear")
      assert errors["routes[0].auth.type"] == ~s(expected one of "api_key", got: "jwt")
      assert errors["routes[0].upstream.balance"] =~ "expected one of"
    end

    test "an upstream needs exactly one of url or targets" do
      neither = errors(raw_config([raw_route(%{"upstream" => %{"timeout" => "1s"}})]))
      assert neither["routes[0].upstream"] == ~s(must have either "url" or "targets")

      both =
        errors(
          raw_config([raw_route(%{"upstream" => %{"url" => "http://a:1", "targets" => [%{"url" => "http://b:1"}]}})])
        )

      assert both["routes[0].upstream"] == ~s(must have either "url" or "targets", not both)

      empty = errors(raw_config([raw_route(%{"upstream" => %{"targets" => []}})]))
      assert empty["routes[0].upstream.targets"] =~ "non-empty list"
    end

    test "rejects malformed urls, methods, paths, and status codes" do
      route =
        raw_route(%{
          "path" => "api",
          "methods" => ["GET", "FETCH"],
          "upstream" => %{"targets" => [%{"url" => "localhost:3000"}, %{"url" => "http://ok:1", "weight" => 0}]},
          "retry" => %{"attempts" => 0, "on" => [200, 999]}
        })

      errors = errors(raw_config([route]))
      assert errors["routes[0].path"] == ~s(expected a path starting with "/", got: "api")
      assert errors["routes[0].methods"] =~ ~s(unknown HTTP methods ["FETCH"])
      assert errors["routes[0].upstream.targets[0].url"] == ~s|expected an http(s) URL, got: "localhost:3000"|
      assert errors["routes[0].upstream.targets[1].weight"] == "expected a positive integer, got: 0"
      assert errors["routes[0].retry.attempts"] == "expected a positive integer, got: 0"
      assert errors["routes[0].retry.on"] =~ "expected a list of HTTP status codes"
    end

    test "unknown $variables in transforms are fatal, $literal escapes are not" do
      route =
        raw_route(%{
          "request_transform" => %{
            "headers" => %{"add" => %{"X-Ok" => "$literal:$fine", "X-Bad" => "$reqest_time"}},
            "body" => %{"mapping" => %{"a.b" => "$nope"}}
          },
          "response_transform" => %{"body" => %{"envelope" => %{"data" => "$body", "meta" => %{"t" => "$now"}}}}
        })

      errors = errors(raw_config([route]))
      assert errors["routes[0].request_transform.headers.add.x-bad"] =~ ~s(unknown variable "$reqest_time")
      assert errors["routes[0].request_transform.body.mapping.a.b"] =~ ~s(unknown variable "$nope")
      assert errors["routes[0].response_transform.body.envelope.meta.t"] =~ ~s(unknown variable "$now")
      refute Map.has_key?(errors, "routes[0].request_transform.headers.add.x-ok")
    end

    test "a missing or malformed gateway section is reported alongside route errors" do
      assert %{"gateway" => "is required", "routes[0].path" => "is required"} =
               errors(%{"routes" => [%{"upstream" => %{"url" => "http://h:1"}}]})

      assert %{"gateway" => "expected a map, got: [1]"} = errors(%{"gateway" => [1]})
      assert %{"routes" => "expected a list of routes, got: %{}"} = errors(raw_config(%{}))
      assert %{"" => message} = errors([])
      assert message =~ "expected a map"
    end
  end

  describe "GatewayKit.Config.Validator.validate/1 warnings" do
    test "unknown keys anywhere in the tree warn but never fail" do
      raw = %{
        "gateway" => %{"port" => 1, "global_ratelimit" => %{}},
        "routes" => [
          raw_route(%{
            "methods" => ["GET"],
            "strip_prefx" => true,
            "upstream" => %{"targets" => [%{"url" => "http://h:1", "wieght" => 2}]},
            "retry" => %{"attempts" => 1, "max_delay" => "1s"},
            "request_transform" => %{"headers" => %{"add" => %{"X-Free" => "form"}}, "extra" => 1}
          })
        ]
      }

      assert {:ok, %Config{warnings: warnings}} = Validator.validate(raw)

      assert Enum.sort(Enum.map(warnings, & &1.path)) == [
               "gateway.global_ratelimit",
               "routes[0].request_transform.extra",
               "routes[0].retry.max_delay",
               "routes[0].strip_prefx",
               "routes[0].upstream.targets[0].wieght"
             ]

      assert Enum.all?(warnings, &(&1.message == "unknown key, ignored"))
    end
  end
end
