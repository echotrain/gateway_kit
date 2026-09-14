defmodule GatewayKit.Stage.CircuitBreakerTest do
  use GatewayKit.GatewayCase, async: true

  @moduletag :capture_log

  setup do
    upstream = start_supervised!(MockUpstream)
    port = MockUpstream.port(upstream)
    gateway = start_gateway_from_yaml("test/support/configs/breaker.yaml", %{UPSTREAM_PORT: port})
    %{gateway: gateway, upstream: upstream, url: MockUpstream.url(upstream)}
  end

  defp status(gateway, path) do
    {:ok, response} = request(gateway, :get, path)
    response.status
  end

  describe "circuit breaker end to end" do
    test "trips after the configured failures and answers with the mandated 503", context do
      %{gateway: gateway, upstream: upstream} = context

      assert [503, 503, 503] = for(_ <- 1..3, do: status(gateway, "/api/fragile/status/503"))

      {:ok, rejected} = request(gateway, :get, "/api/fragile/canned")

      assert rejected.status == 503
      assert %{"error" => "service_unavailable", "retry_after" => retry_after} = json(rejected)
      assert is_integer(retry_after) and retry_after in 1..30
      assert header(rejected, "retry-after") == Integer.to_string(retry_after)
      assert length(MockUpstream.requests(upstream)) == 3
    end

    test "4xx responses are healthy answers and never count", %{gateway: gateway} do
      for _ <- 1..5, do: assert(status(gateway, "/api/fragile/status/404") == 404)

      assert status(gateway, "/api/fragile/canned") == 200
    end

    test "gateway-generated 502s count as failures", %{gateway: gateway, upstream: upstream} do
      :ok = MockUpstream.stop(upstream)

      assert [502, 502, 502] = for(_ <- 1..3, do: status(gateway, "/api/fragile"))
      assert %{"error" => "service_unavailable"} = gateway |> request(:get, "/api/fragile") |> elem(1) |> json()
    end

    test "a request that exhausts its retries counts as one failure", %{url: url, upstream: upstream} do
      retry = %{"attempts" => 3, "backoff" => "fixed", "initial_delay" => "1ms", "on" => [503]}
      breaker = %{"threshold" => 2, "window" => "60s", "cooldown" => "30s"}
      gateway = start_gateway(config([route("/api", url, %{"retry" => retry, "circuit_breaker" => breaker})]))

      assert status(gateway, "/api/status/503") == 503
      assert length(MockUpstream.requests(upstream)) == 3

      assert status(gateway, "/api/status/503") == 503
      assert length(MockUpstream.requests(upstream)) == 6

      assert %{"error" => "service_unavailable"} = gateway |> request(:get, "/api/canned") |> elem(1) |> json()
      assert length(MockUpstream.requests(upstream)) == 6
    end
  end
end
