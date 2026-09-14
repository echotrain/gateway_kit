defmodule GatewayKit.RateLimitTest do
  use ExUnit.Case, async: true

  alias GatewayKit.Config.RateLimit, as: Policy
  alias GatewayKit.RateLimit
  alias GatewayKit.RateLimit.Window
  alias GatewayKit.Store

  @window 60_000

  setup do
    %{start: Window.starts_at(Window.index(System.system_time(:millisecond), @window) + 1, @window)}
  end

  describe "GatewayKit.RateLimit.check/3" do
    test "dispatches on the policy's strategy", %{start: start} do
      key = {System.unique_integer([:positive]), :global}

      assert {:allow, %{limit: 1}} = RateLimit.check(%Policy{requests: 1, window_ms: @window}, key, start)

      assert {:deny, _} =
               RateLimit.check(%Policy{requests: 1, window_ms: @window, strategy: :sliding_window}, key, start)
    end

    test "under 50 simultaneous requests against a limit of 10, exactly 10 are allowed", %{start: start} do
      for strategy <- [:fixed_window, :sliding_window] do
        policy = %Policy{requests: 10, window_ms: @window, strategy: strategy}
        key = {System.unique_integer([:positive]), "10.0.0.1"}

        decisions =
          1..50
          |> Task.async_stream(fn _ -> RateLimit.check(policy, key, start) end, max_concurrency: 50, ordered: false)
          |> Enum.map(fn {:ok, {decision, _info}} -> decision end)

        assert Enum.frequencies(decisions) == %{allow: 10, deny: 40}, "#{strategy} let the wrong number through"
      end
    end
  end

  describe "GatewayKit.Store.sweep/1" do
    test "removes windowed rows once their expiry has passed", %{start: start} do
      key = {System.unique_integer([:positive]), "10.0.0.1"}
      index = Window.index(start, @window)
      Window.increment(Store.rate_limits(), key, index, @window)

      Store.sweep(Window.starts_at(index + 2, @window) - 1)
      assert Window.count(Store.rate_limits(), key, index) == 1

      Store.sweep(Window.starts_at(index + 2, @window) + 1)
      assert Window.count(Store.rate_limits(), key, index) == 0
    end
  end
end
