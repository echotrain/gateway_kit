defmodule GatewayKit.Breaker do
  @moduledoc """
  Per-route circuit breaker state machine, kept in ETS with no process on the request path.

      closed ──(threshold failures within window)──▶ open
        ▲                                             │ cooldown elapses
        │ trial succeeds                              ▼
        └──────────────────────────────────────── half-open ──(trial fails)──▶ open

  * **closed** — requests flow; failures are counted in a rolling window (the sliding-window
    counter from rate limiting, keyed `{:breaker, route_id}`).
  * **open** — requests are rejected with the remaining cooldown, so the client can be told
    `retry_after` exactly.
  * **half-open** — once the cooldown elapses, exactly **one** request is let through as a trial.
    The transition is an atomic compare-and-swap (`:ets.select_replace/2`), so fifty requests
    arriving at cooldown expiry produce one trial and forty-nine rejections, not a thundering
    herd against an upstream that may still be down. A trial whose outcome never arrives (the
    trial process died) is treated as stale after another cooldown, and a new trial is allowed.

  A failure is any 5xx — an upstream 5xx or a gateway-generated 502/504. A 4xx is a healthy
  upstream answering correctly and is never counted.

  `now_ms` is an explicit argument everywhere so state transitions are testable without sleeping.
  """

  alias GatewayKit.Config.CircuitBreaker
  alias GatewayKit.RateLimit.Window
  alias GatewayKit.Store

  @type state :: :closed | :open | :half_open
  @type outcome :: :success | :failure
  @type check :: :allow | {:reject, retry_after_ms :: non_neg_integer()}

  @doc "The breaker's current state for `route_id`."
  @spec state(term()) :: state()
  def state(route_id) do
    case :ets.lookup(Store.breakers(), route_id) do
      [{^route_id, state, _since}] -> state
      [] -> :closed
    end
  end

  @doc "Decides whether a request may proceed at `now_ms`."
  @spec check(term(), CircuitBreaker.t(), integer()) :: check()
  def check(route_id, %CircuitBreaker{cooldown_ms: cooldown_ms}, now_ms) do
    case :ets.lookup(Store.breakers(), route_id) do
      [] -> :allow
      [{^route_id, :closed, _since}] -> :allow
      [{^route_id, :open, since}] when since + cooldown_ms > now_ms -> {:reject, since + cooldown_ms - now_ms}
      [{^route_id, :open, since}] -> claim_trial(route_id, :open, since, now_ms)
      # A trial is in flight: the cooldown has elapsed, so there is nothing left to wait out.
      [{^route_id, :half_open, since}] when since + cooldown_ms > now_ms -> {:reject, 0}
      [{^route_id, :half_open, since}] -> claim_trial(route_id, :half_open, since, now_ms)
    end
  end

  @doc "Records how an allowed request ended, at `now_ms`."
  @spec record(term(), CircuitBreaker.t(), outcome(), integer()) :: :ok
  def record(route_id, %CircuitBreaker{}, :success, now_ms) do
    case state(route_id) do
      :half_open -> close(route_id, now_ms)
      _other -> :ok
    end
  end

  def record(route_id, %CircuitBreaker{} = breaker, :failure, now_ms) do
    case state(route_id) do
      :half_open -> trip(route_id, now_ms)
      :open -> :ok
      :closed -> count_failure(route_id, breaker, now_ms)
    end
  end

  # Only the caller whose compare-and-swap succeeds becomes the trial; everyone else is rejected.
  # The swap is guarded on the exact `{state, since}` that was observed, so two racing callers
  # cannot both win.
  defp claim_trial(route_id, state, since, now_ms) do
    spec = [{{route_id, state, since}, [], [{{route_id, :half_open, now_ms}}]}]

    case :ets.select_replace(Store.breakers(), spec) do
      1 -> :allow
      0 -> {:reject, 0}
    end
  end

  defp count_failure(route_id, %CircuitBreaker{threshold: threshold, window_ms: window_ms}, now_ms) do
    key = {:breaker, route_id}
    index = Window.index(now_ms, window_ms)
    elapsed_fraction = (now_ms - Window.starts_at(index, window_ms)) / window_ms

    previous = Window.count(Store.windows(), key, index - 1)
    current = Window.increment(Store.windows(), key, index, window_ms)

    if previous * (1 - elapsed_fraction) + current >= threshold, do: trip(route_id, now_ms), else: :ok
  end

  defp trip(route_id, now_ms) do
    :ets.insert(Store.breakers(), {route_id, :open, now_ms})
    :ok
  end

  # Recovery starts with a clean slate: the failures that tripped the breaker must not re-trip it
  # on the first post-recovery hiccup.
  defp close(route_id, now_ms) do
    :ets.insert(Store.breakers(), {route_id, :closed, now_ms})
    :ets.match_delete(Store.windows(), {{{:breaker, route_id}, :_}, :_, :_})
    :ok
  end
end
