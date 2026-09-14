defmodule GatewayKit.Config.Validator do
  @moduledoc """
  Turns the raw YAML map into typed, fully-resolved config structs — or a list of every problem
  found, so a malformed file is reported once, completely, rather than one error per boot.

  Principles:

  * **The whole schema is understood here**, including features the gateway may not implement
    yet. A config that uses `targets:`, `health_check:` or `request_transform:` always loads.
  * **Unknown keys warn, unknown enum values fail.** A misspelled key is forward-compatible
    noise; `strategy: "token_bucket"` silently falling back to a different limiter is not.
  * **Globals are folded in at load time.** Each route carries its own timeout and rate limit,
    so nothing on the request path consults `gateway.*` defaults.
  * **`url:` and `targets:` normalize to one shape** — a non-empty list of `%Target{}`.
  """

  alias GatewayKit.Config

  alias GatewayKit.Config.{
    Auth,
    CircuitBreaker,
    Duration,
    Error,
    HealthCheck,
    RateLimit,
    Retry,
    Route,
    Target,
    Transform,
    Upstream
  }

  @default_timeout_ms 30_000
  @methods ~w(GET HEAD POST PUT PATCH DELETE OPTIONS TRACE CONNECT)
  @strategies %{"fixed_window" => :fixed_window, "sliding_window" => :sliding_window}
  @per %{"ip" => :ip, "global" => :global}
  @backoffs %{"fixed" => :fixed, "exponential" => :exponential}
  @balances %{"round_robin" => :round_robin, "weighted_round_robin" => :weighted_round_robin}
  @auth_types %{"api_key" => :api_key}
  @schemes ~w(http https)

  # Allowed keys per section. `:leaf` means "do not descend"; free-form maps (`headers.add`,
  # `body.mapping`, `body.envelope`) are leaves because their keys are user data.
  @rate_limit_schema %{"requests" => :leaf, "window" => :leaf, "strategy" => :leaf, "per" => :leaf}
  @headers_schema %{"add" => :leaf, "remove" => :leaf}
  @schema %{
    "gateway" => %{"port" => :leaf, "global_timeout" => :leaf, "global_rate_limit" => @rate_limit_schema},
    "routes" =>
      {:list,
       %{
         "path" => :leaf,
         "methods" => :leaf,
         "strip_prefix" => :leaf,
         "upstream" => %{
           "url" => :leaf,
           "targets" => {:list, %{"url" => :leaf, "weight" => :leaf}},
           "balance" => :leaf,
           "timeout" => :leaf
         },
         "rate_limit" => @rate_limit_schema,
         "retry" => %{"attempts" => :leaf, "backoff" => :leaf, "initial_delay" => :leaf, "on" => :leaf},
         "health_check" => %{"path" => :leaf, "interval" => :leaf, "unhealthy_threshold" => :leaf},
         "request_transform" => %{"headers" => @headers_schema, "body" => %{"mapping" => :leaf}},
         "response_transform" => %{"headers" => @headers_schema, "body" => %{"envelope" => :leaf}},
         "auth" => %{"type" => :leaf, "header" => :leaf, "keys" => :leaf},
         "circuit_breaker" => %{"threshold" => :leaf, "window" => :leaf, "cooldown" => :leaf}
       }}
  }

  @typep result(value) :: {:ok, value} | {:error, [Error.t()]}

  @doc "Validates a raw (string-keyed) config map, as produced by the YAML parser."
  @spec validate(term()) :: {:ok, Config.t()} | {:error, [Error.t()]}
  def validate(raw) when is_map(raw) do
    gateway = gateway(Map.get(raw, "gateway"))
    routes = routes(Map.get(raw, "routes"), defaults(gateway))

    with {:ok, %{gateway: gateway, routes: routes}} <- collect(gateway: gateway, routes: routes) do
      fields = Map.merge(gateway, %{routes: routes, warnings: unknown_keys(raw, @schema, "")})
      {:ok, struct!(Config, fields)}
    end
  end

  def validate(other) do
    error("", ~s(expected a map with "gateway" and "routes" sections, got: #{inspect(other)}))
  end

  # ---------------------------------------------------------------------------
  # Sections
  # ---------------------------------------------------------------------------

  defp gateway(nil), do: error("gateway", "is required")

  defp gateway(raw) when is_map(raw) do
    collect(
      port: required(raw, "port", "gateway.port", &port/2),
      global_timeout_ms: optional(raw, "global_timeout", "gateway.global_timeout", &duration/2, @default_timeout_ms),
      global_rate_limit: optional(raw, "global_rate_limit", "gateway.global_rate_limit", &rate_limit/2, nil)
    )
  end

  defp gateway(other), do: error("gateway", "expected a map, got: #{inspect(other)}")

  # Route validation still runs when the gateway section is broken, so every error is reported
  # in one pass; the placeholder defaults are never used in that case.
  defp defaults({:ok, %{global_timeout_ms: timeout_ms, global_rate_limit: rate_limit}}) do
    %{timeout_ms: timeout_ms, rate_limit: rate_limit}
  end

  defp defaults({:error, _errors}), do: %{timeout_ms: @default_timeout_ms, rate_limit: nil}

  defp routes(nil, _defaults), do: {:ok, []}

  defp routes(raw, defaults) when is_list(raw) do
    raw
    |> Enum.with_index(fn route, index -> route(route, "routes[#{index}]", defaults) end)
    |> merge()
  end

  defp routes(other, _defaults), do: error("routes", "expected a list of routes, got: #{inspect(other)}")

  defp route(raw, path, defaults) when is_map(raw) do
    fields =
      collect(
        path: required(raw, "path", "#{path}.path", &route_path/2),
        methods: optional(raw, "methods", "#{path}.methods", &methods/2, @methods),
        strip_prefix: optional(raw, "strip_prefix", "#{path}.strip_prefix", &boolean/2, false),
        upstream: required(raw, "upstream", "#{path}.upstream", &upstream(&1, &2, defaults.timeout_ms)),
        rate_limit: optional(raw, "rate_limit", "#{path}.rate_limit", &rate_limit/2, defaults.rate_limit),
        retry: optional(raw, "retry", "#{path}.retry", &retry/2, nil),
        circuit_breaker: optional(raw, "circuit_breaker", "#{path}.circuit_breaker", &circuit_breaker/2, nil),
        auth: optional(raw, "auth", "#{path}.auth", &auth/2, nil),
        request_transform: optional(raw, "request_transform", "#{path}.request_transform", &request_transform/2, nil),
        response_transform:
          optional(raw, "response_transform", "#{path}.response_transform", &response_transform/2, nil),
        health_check: optional(raw, "health_check", "#{path}.health_check", &health_check/2, nil)
      )

    with {:ok, fields} <- fields do
      id = System.unique_integer([:positive, :monotonic])
      {:ok, struct!(Route, Map.merge(fields, %{id: id, segments: String.split(fields.path, "/", trim: true)}))}
    end
  end

  defp route(other, path, _defaults), do: error(path, "expected a map, got: #{inspect(other)}")

  defp upstream(raw, path, default_timeout_ms) when is_map(raw) do
    fields =
      collect(
        targets: targets(raw, path),
        balance: optional(raw, "balance", "#{path}.balance", &enum(&1, &2, @balances), :round_robin),
        timeout_ms: optional(raw, "timeout", "#{path}.timeout", &duration/2, default_timeout_ms)
      )

    with {:ok, fields} <- fields do
      {:ok, struct!(Upstream, Map.put(fields, :ring, ring(fields.targets, fields.balance)))}
    end
  end

  defp upstream(other, path, _default), do: error(path, "expected a map, got: #{inspect(other)}")

  defp targets(raw, path) do
    case {Map.get(raw, "url"), Map.get(raw, "targets")} do
      {nil, nil} -> error(path, ~s(must have either "url" or "targets"))
      {_url, nil} -> merge([target(raw, path)])
      {nil, list} when is_list(list) and list != [] -> target_list(list, "#{path}.targets")
      {nil, other} -> error("#{path}.targets", "expected a non-empty list of targets, got: #{inspect(other)}")
      {_url, _list} -> error(path, ~s(must have either "url" or "targets", not both))
    end
  end

  defp target_list(list, path) do
    list
    |> Enum.with_index(fn target, index -> target(target, "#{path}[#{index}]") end)
    |> merge()
  end

  defp target(raw, path) when is_map(raw) do
    fields =
      collect(
        uri: required(raw, "url", "#{path}.url", &url/2),
        weight: optional(raw, "weight", "#{path}.weight", &positive_integer/2, 1)
      )

    with {:ok, %{uri: uri, weight: weight}} <- fields do
      {:ok, %Target{url: URI.to_string(uri), uri: uri, weight: weight}}
    end
  end

  defp target(other, path), do: error(path, "expected a map with \"url\", got: #{inspect(other)}")

  defp ring(targets, :round_robin), do: List.to_tuple(targets)

  defp ring(targets, :weighted_round_robin) do
    targets
    |> Enum.flat_map(&List.duplicate(&1, &1.weight))
    |> List.to_tuple()
  end

  defp rate_limit(raw, path) when is_map(raw) do
    fields =
      collect(
        requests: required(raw, "requests", "#{path}.requests", &positive_integer/2),
        window_ms: required(raw, "window", "#{path}.window", &duration/2),
        strategy: optional(raw, "strategy", "#{path}.strategy", &enum(&1, &2, @strategies), :fixed_window),
        per: optional(raw, "per", "#{path}.per", &enum(&1, &2, @per), :ip)
      )

    build(fields, RateLimit)
  end

  defp rate_limit(other, path), do: error(path, "expected a map, got: #{inspect(other)}")

  defp retry(raw, path) when is_map(raw) do
    fields =
      collect(
        attempts: required(raw, "attempts", "#{path}.attempts", &positive_integer/2),
        backoff: optional(raw, "backoff", "#{path}.backoff", &enum(&1, &2, @backoffs), :exponential),
        initial_delay_ms: optional(raw, "initial_delay", "#{path}.initial_delay", &delay/2, 100),
        on: optional(raw, "on", "#{path}.on", &status_codes/2, [502, 503, 504])
      )

    build(fields, Retry)
  end

  defp retry(other, path), do: error(path, "expected a map, got: #{inspect(other)}")

  defp circuit_breaker(raw, path) when is_map(raw) do
    fields =
      collect(
        threshold: required(raw, "threshold", "#{path}.threshold", &positive_integer/2),
        window_ms: optional(raw, "window", "#{path}.window", &duration/2, 60_000),
        cooldown_ms: optional(raw, "cooldown", "#{path}.cooldown", &duration/2, 30_000)
      )

    build(fields, CircuitBreaker)
  end

  defp circuit_breaker(other, path), do: error(path, "expected a map, got: #{inspect(other)}")

  defp auth(raw, path) when is_map(raw) do
    fields =
      collect(
        type: required(raw, "type", "#{path}.type", &enum(&1, &2, @auth_types)),
        header: required(raw, "header", "#{path}.header", &header_name/2),
        keys: required(raw, "keys", "#{path}.keys", &string_list/2)
      )

    build(fields, Auth)
  end

  defp auth(other, path), do: error(path, "expected a map, got: #{inspect(other)}")

  defp health_check(raw, path) when is_map(raw) do
    fields =
      collect(
        path: required(raw, "path", "#{path}.path", &route_path/2),
        interval_ms: optional(raw, "interval", "#{path}.interval", &duration/2, 30_000),
        unhealthy_threshold: optional(raw, "unhealthy_threshold", "#{path}.unhealthy_threshold", &positive_integer/2, 3)
      )

    build(fields, HealthCheck)
  end

  defp health_check(other, path), do: error(path, "expected a map, got: #{inspect(other)}")

  defp request_transform(raw, path), do: transform(raw, path, "mapping", &mapping/2)
  defp response_transform(raw, path), do: transform(raw, path, "envelope", &envelope/2)

  defp transform(raw, path, body_key, body_parser) when is_map(raw) do
    with {:ok, headers} <- optional(raw, "headers", "#{path}.headers", &map/2, %{}),
         {:ok, body} <- optional(raw, "body", "#{path}.body", &map/2, %{}) do
      fields =
        collect(
          add_headers: optional(headers, "add", "#{path}.headers.add", &header_values/2, []),
          remove_headers: optional(headers, "remove", "#{path}.headers.remove", &header_names/2, []),
          body: optional(body, body_key, "#{path}.body.#{body_key}", body_parser, nil)
        )

      build(fields, Transform)
    end
  end

  defp transform(other, path, _body_key, _body_parser), do: error(path, "expected a map, got: #{inspect(other)}")

  defp mapping(raw, path) when is_map(raw) and map_size(raw) > 0 do
    raw
    |> Enum.map(fn {destination, source} -> mapping_entry(destination, source, path) end)
    |> merge()
    |> tag(:mapping)
  end

  defp mapping(other, path), do: error(path, "expected a map of destination.path: source, got: #{inspect(other)}")

  defp mapping_entry(destination, source, path) when is_binary(destination) and destination != "" do
    with {:ok, source} <- mapping_source(source, "#{path}.#{destination}") do
      {:ok, {String.split(destination, "."), source}}
    end
  end

  defp mapping_entry(destination, _source, path) do
    error(path, "expected a dotted destination path, got: #{inspect(destination)}")
  end

  defp mapping_source("$" <> _ = dynamic, path), do: value(dynamic, path)

  defp mapping_source(source, _path) when is_binary(source) and source != "",
    do: {:ok, {:path, String.split(source, ".")}}

  defp mapping_source(other, path), do: error(path, "expected a source path or $value, got: #{inspect(other)}")

  defp envelope(raw, path) when is_map(raw) and map_size(raw) > 0 do
    raw
    |> template(path)
    |> tag(:envelope)
  end

  defp envelope(other, path), do: error(path, "expected an envelope map, got: #{inspect(other)}")

  # Walks a JSON-like template, parsing string leaves into values and keeping other scalars.
  defp template(raw, path) when is_map(raw) do
    raw
    |> Enum.map(fn {key, child} ->
      with {:ok, parsed} <- template(child, "#{path}.#{key}"), do: {:ok, {to_string(key), parsed}}
    end)
    |> merge()
    |> map_result(&Map.new/1)
  end

  defp template(raw, path) when is_list(raw) do
    raw
    |> Enum.with_index(fn child, index -> template(child, "#{path}[#{index}]") end)
    |> merge()
  end

  defp template(raw, path) when is_binary(raw), do: value(raw, path)
  defp template(raw, _path), do: {:ok, raw}

  # ---------------------------------------------------------------------------
  # Leaf parsers — all `(raw, path) -> result`
  # ---------------------------------------------------------------------------

  defp port(value, _path) when is_integer(value) and value in 1..65_535, do: {:ok, value}
  defp port(value, path), do: error(path, "expected an integer 1..65535, got: #{inspect(value)}")

  defp duration(value, path) do
    case Duration.parse(value) do
      {:ok, ms} when ms > 0 -> {:ok, ms}
      _ -> error(path, ~s(expected a duration like "60s", got: #{inspect(value)}))
    end
  end

  defp delay(value, path) do
    case Duration.parse(value) do
      {:ok, ms} -> {:ok, ms}
      :error -> error(path, ~s(expected a duration like "1s", got: #{inspect(value)}))
    end
  end

  defp positive_integer(value, _path) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(value, path), do: error(path, "expected a positive integer, got: #{inspect(value)}")

  defp boolean(value, _path) when is_boolean(value), do: {:ok, value}
  defp boolean(value, path), do: error(path, "expected true or false, got: #{inspect(value)}")

  defp map(value, _path) when is_map(value), do: {:ok, value}
  defp map(value, path), do: error(path, "expected a map, got: #{inspect(value)}")

  defp route_path("/" <> _ = value, _path), do: {:ok, value}
  defp route_path(value, path), do: error(path, ~s(expected a path starting with "/", got: #{inspect(value)}))

  defp enum(value, path, allowed) do
    case Map.fetch(allowed, value) do
      {:ok, atom} ->
        {:ok, atom}

      :error ->
        options = allowed |> Map.keys() |> Enum.sort() |> Enum.map_join(", ", &inspect/1)
        error(path, "expected one of #{options}, got: #{inspect(value)}")
    end
  end

  defp methods(value, path) when is_list(value) and value != [] do
    upcased = Enum.map(value, &upcase_method/1)

    case Enum.reject(upcased, &(&1 in @methods)) do
      [] -> {:ok, Enum.uniq(upcased)}
      unknown -> error(path, "unknown HTTP methods #{inspect(unknown)}; expected any of #{inspect(@methods)}")
    end
  end

  defp methods(value, path),
    do: error(path, ~s(expected a list of methods like ["GET", "POST"], got: #{inspect(value)}))

  defp upcase_method(method) when is_binary(method), do: String.upcase(method)
  defp upcase_method(other), do: other

  defp url(value, path) when is_binary(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: scheme, host: host} = uri} when scheme in @schemes and is_binary(host) and host != "" ->
        {:ok, %URI{uri | path: String.trim_trailing(uri.path || "", "/"), query: nil, fragment: nil}}

      _ ->
        error(path, "expected an http(s) URL, got: #{inspect(value)}")
    end
  end

  defp url(value, path), do: error(path, "expected an http(s) URL, got: #{inspect(value)}")

  defp status_codes(value, path) when is_list(value) and value != [] do
    if Enum.all?(value, &(is_integer(&1) and &1 in 100..599)) do
      {:ok, Enum.uniq(value)}
    else
      error(path, "expected a list of HTTP status codes, got: #{inspect(value)}")
    end
  end

  defp status_codes(value, path), do: error(path, "expected a list of HTTP status codes, got: #{inspect(value)}")

  defp string_list(value, path) when is_list(value) and value != [] do
    if Enum.all?(value, &(is_binary(&1) and &1 != "")) do
      {:ok, value}
    else
      error(path, "expected a non-empty list of strings, got: #{inspect(value)}")
    end
  end

  defp string_list(value, path), do: error(path, "expected a non-empty list of strings, got: #{inspect(value)}")

  defp header_name(value, _path) when is_binary(value) and value != "", do: {:ok, String.downcase(value)}
  defp header_name(value, path), do: error(path, "expected a header name, got: #{inspect(value)}")

  defp header_names(value, path) when is_list(value) do
    value
    |> Enum.with_index(fn name, index -> header_name(name, "#{path}[#{index}]") end)
    |> merge()
  end

  defp header_names(value, path), do: error(path, "expected a list of header names, got: #{inspect(value)}")

  defp header_values(value, path) when is_map(value) do
    value
    |> Enum.map(fn {name, raw} -> header_value(name, raw, path) end)
    |> merge()
  end

  defp header_values(value, path), do: error(path, "expected a map of header: value, got: #{inspect(value)}")

  defp header_value(name, raw, path) do
    with {:ok, name} <- header_name(name, path),
         {:ok, value} <- value(raw, "#{path}.#{name}") do
      {:ok, {name, value}}
    end
  end

  defp value("$literal:" <> literal, _path), do: {:ok, {:literal, literal}}

  defp value("$" <> _ = variable, path) do
    if variable in Transform.variables() do
      {:ok, {:var, variable}}
    else
      known = Enum.join(Transform.variables() ++ ["$literal:<text>"], ", ")
      error(path, "unknown variable #{inspect(variable)}; expected one of #{known}")
    end
  end

  defp value(literal, _path) when is_binary(literal), do: {:ok, {:literal, literal}}
  defp value(other, path), do: error(path, "expected a string, got: #{inspect(other)}")

  # ---------------------------------------------------------------------------
  # Unknown-key detection (warnings, never fatal)
  # ---------------------------------------------------------------------------

  defp unknown_keys(raw, schema, path) when is_map(raw) and is_map(schema) do
    Enum.flat_map(raw, fn {key, child} ->
      child_path = join(path, key)

      case Map.fetch(schema, to_string(key)) do
        {:ok, :leaf} -> []
        {:ok, child_schema} -> unknown_keys(child, child_schema, child_path)
        :error -> [Error.new(child_path, "unknown key, ignored")]
      end
    end)
  end

  defp unknown_keys(raw, {:list, schema}, path) when is_list(raw) do
    raw
    |> Enum.with_index()
    |> Enum.flat_map(fn {child, index} -> unknown_keys(child, schema, "#{path}[#{index}]") end)
  end

  # Type mismatches are reported by the typed pass; nothing to warn about here.
  defp unknown_keys(_raw, _schema, _path), do: []

  defp join("", key), do: to_string(key)
  defp join(path, key), do: "#{path}.#{key}"

  # ---------------------------------------------------------------------------
  # Result plumbing
  # ---------------------------------------------------------------------------

  defp required(raw, key, path, parser) do
    case Map.get(raw, key) do
      nil -> error(path, "is required")
      value -> parser.(value, path)
    end
  end

  defp optional(raw, key, path, parser, default) do
    case Map.get(raw, key) do
      nil -> {:ok, default}
      value -> parser.(value, path)
    end
  end

  # Gathers `[key: result]` pairs into `{:ok, %{key => value}}` or every error found.
  @spec collect([{atom(), result(term())}]) :: result(map())
  defp collect(fields) do
    Enum.reduce(fields, {:ok, %{}}, fn
      {key, {:ok, value}}, {:ok, acc} -> {:ok, Map.put(acc, key, value)}
      {_key, {:ok, _value}}, {:error, _} = errors -> errors
      {_key, {:error, errors}}, {:ok, _acc} -> {:error, errors}
      {_key, {:error, errors}}, {:error, acc} -> {:error, acc ++ errors}
    end)
  end

  # Gathers a list of results into `{:ok, [value]}` (order preserved) or every error found.
  @spec merge([result(term())]) :: result([term()])
  defp merge(results) do
    results
    |> Enum.with_index(fn result, index -> {index, result} end)
    |> collect()
    |> map_result(fn by_index -> by_index |> Enum.sort() |> Enum.map(&elem(&1, 1)) end)
  end

  defp build({:ok, fields}, module), do: {:ok, struct!(module, fields)}
  defp build({:error, _errors} = errors, _module), do: errors

  defp tag({:ok, value}, tag), do: {:ok, {tag, value}}
  defp tag({:error, _errors} = errors, _tag), do: errors

  defp map_result({:ok, value}, fun), do: {:ok, fun.(value)}
  defp map_result({:error, _errors} = errors, _fun), do: errors

  defp error(path, message), do: {:error, [Error.new(path, message)]}
end
