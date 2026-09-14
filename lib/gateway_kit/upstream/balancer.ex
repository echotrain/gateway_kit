defmodule GatewayKit.Upstream.Balancer do
  @moduledoc """
  Round-robin target selection over the route's selection ring.

  The ring was expanded at config load: for `round_robin` each target appears once, for
  `weighted_round_robin` each appears `weight` times (`3:1` → `[a, a, a, b]`). Selection is
  therefore the same operation for both — one atomic `:ets.update_counter/4` that advances a
  per-route cursor and wraps it at the ring size, then a constant-time `elem/2`. Under
  concurrency every cursor value is handed out exactly once per cycle, so 400 concurrent requests
  against `3:1` split exactly 300/100, not approximately.
  """

  alias GatewayKit.Config.{Route, Target, Upstream}
  alias GatewayKit.Store

  @spec select(Route.t()) :: Target.t()
  def select(%Route{id: id, upstream: %Upstream{ring: ring}}) do
    # {position, increment, threshold, reset}: past the last slot the cursor wraps to 0.
    cursor = :ets.update_counter(Store.balancer(), id, {2, 1, tuple_size(ring) - 1, 0}, {id, -1})
    elem(ring, cursor)
  end
end
