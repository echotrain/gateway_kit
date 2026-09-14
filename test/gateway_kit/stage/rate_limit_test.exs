defmodule GatewayKit.Stage.RateLimitTest do
  use GatewayKit.GatewayCase, async: true

  setup do
    upstream = start_supervised!(MockUpstream)
    port = MockUpstream.port(upstream)
    gateway = start_gateway_from_yaml("test/support/configs/rate_limit.yaml", %{UPSTREAM_PORT: port})
    %{gateway: gateway, upstream: upstream, url: MockUpstream.url(upstream)}
  end

  defp statuses(gateway, path, count) do
    1..count
    |> Task.async_stream(fn _ -> gateway |> request(:get, path) |> elem(1) |> Map.fetch!(:status) end,
      max_concurrency: count,
      ordered: false
    )
    |> Enum.map(fn {:ok, status} -> status end)
    |> Enum.frequencies()
  end

  describe "rate limiting end to end" do
    test "50 simultaneous requests against a 10-request route: exactly 10 reach the upstream", context do
      %{gateway: gateway, upstream: upstream} = context

      assert statuses(gateway, "/api/limited", 50) == %{200 => 10, 429 => 40}
      assert length(MockUpstream.requests(upstream)) == 10
    end

    test "a rejected request gets the mandated body, Retry-After, and X-RateLimit headers", %{gateway: gateway} do
      for _ <- 1..10, do: request(gateway, :get, "/api/limited")

      {:ok, response} = request(gateway, :get, "/api/limited")

      assert response.status == 429
      assert %{"error" => "rate_limit_exceeded", "retry_after" => retry_after} = json(response)
      assert is_integer(retry_after) and retry_after in 1..3600
      assert header(response, "retry-after") == Integer.to_string(retry_after)
      assert header(response, "x-ratelimit-limit") == "10"
      assert header(response, "x-ratelimit-remaining") == "0"
      assert header(response, "x-ratelimit-reset") == Integer.to_string(retry_after)
    end

    test "allowed responses report the remaining quota", %{gateway: gateway} do
      {:ok, first} = request(gateway, :get, "/api/limited")
      {:ok, _second} = request(gateway, :get, "/api/limited")
      {:ok, third} = request(gateway, :get, "/api/limited")

      assert {200, "10", "9"} =
               {first.status, header(first, "x-ratelimit-limit"), header(first, "x-ratelimit-remaining")}

      assert header(third, "x-ratelimit-remaining") == "7"
    end

    test "the sliding-window strategy enforces its limit", %{gateway: gateway} do
      assert statuses(gateway, "/api/sliding", 15) == %{200 => 10, 429 => 5}
    end

    test "a route without its own policy inherits the global limit, keyed globally", %{gateway: gateway} do
      assert statuses(gateway, "/api/inherited", 7) == %{200 => 5, 429 => 2}

      {:ok, response} = request(gateway, :get, "/api/inherited")
      assert header(response, "x-ratelimit-limit") == "5"
    end

    test "authentication is checked before quota is consumed", %{url: url} do
      auth = %{"type" => "api_key", "header" => "X-Key", "keys" => ["k"]}
      limit = %{"requests" => 1, "window" => "1h"}
      gateway = start_gateway(config([route("/api", url, %{"auth" => auth, "rate_limit" => limit})]))

      {:ok, anonymous} = request(gateway, :get, "/api")
      {:ok, again} = request(gateway, :get, "/api")
      {:ok, allowed} = request(gateway, :get, "/api", headers: [{"x-key", "k"}])
      {:ok, exhausted} = request(gateway, :get, "/api", headers: [{"x-key", "k"}])

      assert [401, 401, 200, 429] == Enum.map([anonymous, again, allowed, exhausted], & &1.status)
    end
  end
end
