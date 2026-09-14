defmodule GatewayKit.RateLimit.FixedWindow do
  @moduledoc """
  Fixed-window counting: `requests` per wall-clock-aligned window.

  One atomic increment per request. The request is allowed when the count *including itself*
  is within the limit, so under `N` simultaneous requests against a limit of `L`, exactly `L`
  succeed regardless of scheduling. Denied requests are not decremented: an over-limit count
  cannot affect this window's decisions and the row expires with the window anyway.
  """

  @behaviour GatewayKit.RateLimit.Strategy

  alias GatewayKit.Config.RateLimit, as: Policy
  alias GatewayKit.RateLimit.Window

  @impl GatewayKit.RateLimit.Strategy
  def check(table, key, %Policy{requests: limit, window_ms: window_ms}, now_ms) do
    index = Window.index(now_ms, window_ms)
    count = Window.increment(table, key, index, window_ms)
    reset_after_ms = Window.starts_at(index + 1, window_ms) - now_ms
    info = %{limit: limit, remaining: max(limit - count, 0), reset_after_ms: reset_after_ms}

    if count <= limit, do: {:allow, info}, else: {:deny, info}
  end
end
