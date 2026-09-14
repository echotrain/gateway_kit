defmodule GatewayKit.RateLimit.SlidingWindowTest do
  use ExUnit.Case, async: true

  alias GatewayKit.Config.RateLimit, as: Policy
  alias GatewayKit.RateLimit.{SlidingWindow, Window}
  alias GatewayKit.Store

  @window 10_000
  @policy %Policy{requests: 10, window_ms: @window, strategy: :sliding_window}

  setup do
    start = Window.starts_at(Window.index(System.system_time(:millisecond), @window) + 1, @window)
    %{key: {System.unique_integer([:positive]), "10.0.0.1"}, start: start, table: Store.rate_limits()}
  end

  defp fill(table, key, at) do
    for i <- 1..10, do: assert({:allow, _} = SlidingWindow.check(table, key, @policy, at + i))
  end

  describe "GatewayKit.RateLimit.SlidingWindow.check/4" do
    test "a full current window denies until it turns over", %{key: key, start: start, table: table} do
      fill(table, key, start)

      assert {:deny, %{limit: 10, remaining: 0, reset_after_ms: 9_989}} =
               SlidingWindow.check(table, key, @policy, start + 11)
    end

    test "weights the previous window by how much of it is still inside the trailing window", context do
      %{key: key, start: start, table: table} = context
      fill(table, key, start)

      # Halfway through the next window, 5 of the previous 10 still count: room for 5 more.
      halfway = start + @window + 5_000
      assert {:allow, %{remaining: 4, reset_after_ms: 5_000}} = SlidingWindow.check(table, key, @policy, halfway)
      for _ <- 1..4, do: assert({:allow, _} = SlidingWindow.check(table, key, @policy, halfway))

      # The next one fits once the previous window has aged to 4: at 60% of this window, in 1s.
      assert {:deny, %{reset_after_ms: 1_000}} = SlidingWindow.check(table, key, @policy, halfway)
      assert {:allow, %{remaining: 0}} = SlidingWindow.check(table, key, @policy, halfway + 1_000)

      # Once the previous window has fully aged out only the current window's 6 count.
      assert {:allow, %{remaining: 3}} = SlidingWindow.check(table, key, @policy, start + 2 * @window)
    end

    test "denied requests do not inflate the next window", %{key: key, start: start, table: table} do
      fill(table, key, start)
      for _ <- 1..50, do: assert({:deny, _} = SlidingWindow.check(table, key, @policy, start + 20))

      assert Window.count(table, key, Window.index(start, @window)) == 10
    end
  end
end
