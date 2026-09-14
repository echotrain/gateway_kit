defmodule GatewayKit.BreakerTest do
  use ExUnit.Case, async: true

  alias GatewayKit.Breaker
  alias GatewayKit.Config.CircuitBreaker
  alias GatewayKit.RateLimit.Window

  @window 60_000
  @breaker %CircuitBreaker{threshold: 3, window_ms: @window, cooldown_ms: 30_000}

  setup do
    start = Window.starts_at(Window.index(System.system_time(:millisecond), @window) + 1, @window)
    %{id: System.unique_integer([:positive]), start: start}
  end

  defp fail(id, at, times), do: for(_ <- 1..times, do: Breaker.record(id, @breaker, :failure, at))

  describe "GatewayKit.Breaker.check/3 and record/4" do
    test "starts closed and trips after `threshold` failures within the window", %{id: id, start: start} do
      assert Breaker.check(id, @breaker, start) == :allow
      fail(id, start, 2)
      assert Breaker.state(id) == :closed

      fail(id, start + 1, 1)
      assert Breaker.state(id) == :open
      assert Breaker.check(id, @breaker, start + 1_000) == {:reject, 29_001}
    end

    test "failures that have aged out of the rolling window do not count", %{id: id, start: start} do
      fail(id, start, 2)
      fail(id, start + 2 * @window, 1)

      assert Breaker.state(id) == :closed
    end

    test "4xx-style successes never trip it and do not reset the window", %{id: id, start: start} do
      fail(id, start, 2)
      Breaker.record(id, @breaker, :success, start + 1)
      assert Breaker.state(id) == :closed

      fail(id, start + 2, 1)
      assert Breaker.state(id) == :open
    end

    test "after the cooldown exactly one concurrent request becomes the trial", %{id: id, start: start} do
      fail(id, start, 3)
      after_cooldown = start + 30_000

      results =
        1..50
        |> Task.async_stream(fn _ -> Breaker.check(id, @breaker, after_cooldown) end, max_concurrency: 50)
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.frequencies(results) == %{:allow => 1, {:reject, 0} => 49}
      assert Breaker.state(id) == :half_open
    end

    test "a successful trial closes the breaker with a clean failure window", %{id: id, start: start} do
      fail(id, start, 3)
      assert Breaker.check(id, @breaker, start + 30_000) == :allow

      Breaker.record(id, @breaker, :success, start + 30_100)
      assert Breaker.state(id) == :closed

      fail(id, start + 30_200, 2)
      assert Breaker.state(id) == :closed
    end

    test "a failed trial reopens the breaker with a fresh cooldown", %{id: id, start: start} do
      fail(id, start, 3)
      assert Breaker.check(id, @breaker, start + 30_000) == :allow

      Breaker.record(id, @breaker, :failure, start + 30_100)
      assert Breaker.state(id) == :open
      assert Breaker.check(id, @breaker, start + 30_200) == {:reject, 29_900}
    end

    test "a trial that never reports back is superseded after another cooldown", %{id: id, start: start} do
      fail(id, start, 3)
      assert Breaker.check(id, @breaker, start + 30_000) == :allow
      assert Breaker.check(id, @breaker, start + 40_000) == {:reject, 0}

      assert Breaker.check(id, @breaker, start + 60_000) == :allow
      assert Breaker.state(id) == :half_open
    end
  end
end
