defmodule GatewayKit.Upstream.LoadBalancingTest do
  use GatewayKit.GatewayCase, async: true

  setup do
    first = start_supervised!(MockUpstream)
    second = start_supervised!(MockUpstream)

    gateway =
      start_gateway_from_yaml("test/support/configs/balance.yaml", %{
        UPSTREAM_PORT: MockUpstream.port(first),
        UPSTREAM_PORT_2: MockUpstream.port(second)
      })

    %{gateway: gateway, first: first, second: second}
  end

  defp served_by(gateway, path, count) do
    1..count
    |> Task.async_stream(fn _ -> gateway |> request(:get, path) |> elem(1) |> header("x-upstream-port") end,
      max_concurrency: 20,
      ordered: false
    )
    |> Enum.map(fn {:ok, port} -> port end)
    |> Enum.frequencies()
  end

  describe "load balancing end to end" do
    test "weighted round robin splits 400 requests 300/100 across a 3:1 pair", context do
      %{gateway: gateway, first: first, second: second} = context

      assert served_by(gateway, "/api/lb", 400) == %{
               Integer.to_string(MockUpstream.port(first)) => 300,
               Integer.to_string(MockUpstream.port(second)) => 100
             }
    end

    test "round robin alternates evenly regardless of weights", %{gateway: gateway, first: first, second: second} do
      assert served_by(gateway, "/api/rr", 40) == %{
               Integer.to_string(MockUpstream.port(first)) => 20,
               Integer.to_string(MockUpstream.port(second)) => 20
             }
    end
  end
end
