defmodule GatewayKit.RateLimit.FixedWindowTest do
  use ExUnit.Case, async: true

  alias GatewayKit.Config.RateLimit, as: Policy
  alias GatewayKit.RateLimit.{FixedWindow, Window}
  alias GatewayKit.Store

  @window 10_000
  @policy %Policy{requests: 3, window_ms: @window, strategy: :fixed_window}

  setup do
    # Start of the *next* real-time window: deterministic arithmetic, and rows the store's
    # timer-driven sweep cannot consider expired.
    start = Window.starts_at(Window.index(System.system_time(:millisecond), @window) + 1, @window)
    %{key: {System.unique_integer([:positive]), "10.0.0.1"}, start: start, table: Store.rate_limits()}
  end

  describe "GatewayKit.RateLimit.FixedWindow.check/4" do
    test "allows `requests` per window, then denies until the window turns over", context do
      %{key: key, start: start, table: table} = context

      assert {:allow, %{limit: 3, remaining: 2, reset_after_ms: 10_000}} = FixedWindow.check(table, key, @policy, start)
      assert {:allow, %{remaining: 1}} = FixedWindow.check(table, key, @policy, start + 1)
      assert {:allow, %{remaining: 0}} = FixedWindow.check(table, key, @policy, start + 2)
      assert {:deny, %{remaining: 0, reset_after_ms: 9_997}} = FixedWindow.check(table, key, @policy, start + 3)
      assert {:deny, %{reset_after_ms: 1}} = FixedWindow.check(table, key, @policy, start + 9_999)

      assert {:allow, %{remaining: 2, reset_after_ms: 10_000}} = FixedWindow.check(table, key, @policy, start + @window)
    end

    test "buckets are independent", %{key: {route_id, _ip}, start: start, table: table} do
      for _ <- 1..3, do: FixedWindow.check(table, {route_id, "10.0.0.1"}, @policy, start)

      assert {:deny, _} = FixedWindow.check(table, {route_id, "10.0.0.1"}, @policy, start)
      assert {:allow, %{remaining: 2}} = FixedWindow.check(table, {route_id, "10.0.0.2"}, @policy, start)
      assert {:allow, %{remaining: 2}} = FixedWindow.check(table, {route_id + 1, "10.0.0.1"}, @policy, start)
    end
  end
end
