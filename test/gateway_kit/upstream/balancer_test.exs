defmodule GatewayKit.Upstream.BalancerTest do
  use ExUnit.Case, async: true

  alias GatewayKit.Config.{Route, Target, Upstream}
  alias GatewayKit.Upstream.Balancer

  defp target(name, weight), do: %Target{url: name, uri: URI.parse("http://#{name}"), weight: weight}

  defp route(targets, balance) do
    ring =
      case balance do
        :round_robin -> List.to_tuple(targets)
        :weighted_round_robin -> targets |> Enum.flat_map(&List.duplicate(&1, &1.weight)) |> List.to_tuple()
      end

    upstream = %Upstream{targets: targets, balance: balance, timeout_ms: 1_000, ring: ring}
    %Route{id: System.unique_integer([:positive]), path: "/x", segments: ["x"], methods: ["GET"], upstream: upstream}
  end

  defp pick(route) do
    {:ok, %Target{url: url}} = Balancer.select(route)
    url
  end

  describe "GatewayKit.Upstream.Balancer.select/1" do
    test "round robin cycles through the targets in order" do
      route = route([target("a", 1), target("b", 5), target("c", 1)], :round_robin)

      assert Enum.map(1..7, fn _ -> pick(route) end) == ~w(a b c a b c a)
    end

    test "weighted round robin distributes by weight, exactly" do
      route = route([target("a", 3), target("b", 1)], :weighted_round_robin)

      assert Enum.map(1..8, fn _ -> pick(route) end) == ~w(a a a b a a a b)
      assert 1..400 |> Enum.map(fn _ -> pick(route) end) |> Enum.frequencies() == %{"a" => 300, "b" => 100}
    end

    test "concurrent selection still hands out every slot exactly once per cycle" do
      route = route([target("a", 3), target("b", 1)], :weighted_round_robin)

      selected =
        1..400
        |> Task.async_stream(fn _ -> pick(route) end, max_concurrency: 50, ordered: false)
        |> Enum.map(fn {:ok, url} -> url end)

      assert Enum.frequencies(selected) == %{"a" => 300, "b" => 100}
    end

    test "a single target is always selected" do
      route = route([target("only", 1)], :round_robin)

      assert Enum.all?(1..3, fn _ -> pick(route) == "only" end)
    end
  end
end
