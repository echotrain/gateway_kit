defmodule GatewayKit.RateLimit.SlidingWindow do
  @moduledoc """
  Sliding-window **counter**: the current window's count plus the previous window's count
  weighted by how much of it still falls inside the trailing `window_ms`.

      estimate = previous × (1 − elapsed_fraction) + current

  Why a counter and not a sliding *log*: a log is exact but stores one entry per request, grows
  with traffic, and needs serialization (or a lock) to stay consistent under concurrency. The
  counter is O(1) memory per bucket, two atomic ETS operations per request, and lock-free. Its
  approximation assumes the previous window's requests were spread evenly; the error is bounded
  and, for gateway rate limiting, well worth the trade (this is the Cloudflare-style algorithm).

  A denied request is decremented again so that hammering a limit does not inflate the next
  window's weighted "previous" count.
  """

  @behaviour GatewayKit.RateLimit.Strategy

  alias GatewayKit.Config.RateLimit, as: Policy
  alias GatewayKit.RateLimit.Window

  @impl GatewayKit.RateLimit.Strategy
  def check(table, key, %Policy{requests: limit, window_ms: window_ms}, now_ms) do
    index = Window.index(now_ms, window_ms)
    starts_at = Window.starts_at(index, window_ms)
    elapsed_fraction = (now_ms - starts_at) / window_ms

    previous = Window.count(table, key, index - 1)
    current = Window.increment(table, key, index, window_ms)
    estimate = previous * (1 - elapsed_fraction) + current

    if estimate <= limit do
      reset_after_ms = starts_at + window_ms - now_ms
      {:allow, %{limit: limit, remaining: trunc(limit - estimate), reset_after_ms: reset_after_ms}}
    else
      Window.decrement(table, key, index, window_ms)
      retry_after_ms = retry_after_ms(previous, current - 1, limit, starts_at, window_ms, now_ms)
      {:deny, %{limit: limit, remaining: 0, reset_after_ms: retry_after_ms}}
    end
  end

  # When will the next request fit? It fits once `previous × (1 − f) + current + 1 <= limit`,
  # i.e. once enough of the previous window has aged out. If the current window alone is already
  # full, nothing ages out that helps until the window turns over.
  defp retry_after_ms(previous, current, limit, starts_at, window_ms, now_ms) do
    needed = limit - current - 1

    if needed < 0 or previous == 0 do
      starts_at + window_ms - now_ms
    else
      fits_at = starts_at + ceil((1 - needed / previous) * window_ms)
      max(fits_at - now_ms, 0)
    end
  end
end
