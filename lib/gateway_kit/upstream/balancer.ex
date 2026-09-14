defmodule GatewayKit.Upstream.Balancer do
  @moduledoc """
  Round-robin target selection over the route's selection ring.

  The ring was expanded at config load: for `round_robin` each target appears once, for
  `weighted_round_robin` each appears `weight` times (`3:1` → `[a, a, a, b]`). Selection is
  therefore the same operation for both — one atomic `:ets.update_counter/4` that advances a
  per-route cursor and wraps it at the ring size, then a constant-time `elem/2`. Under
  concurrency every cursor value is handed out exactly once per cycle, so 400 concurrent requests
  against `3:1` split exactly 300/100, not approximately.

  When the route has active health checks, targets marked unhealthy are skipped in ring order,
  and a route whose targets are all unhealthy fails **closed** with `:no_healthy_upstream` —
  failing open would hammer an upstream we know is down. Routes without health checks never
  consult health state at all.
  """

  alias GatewayKit.Config.{Route, Target, Upstream}
  alias GatewayKit.Store
  alias GatewayKit.Upstream.Health

  @spec select(Route.t()) :: {:ok, Target.t()} | {:error, :no_healthy_upstream}
  def select(%Route{id: id, health_check: nil, upstream: %Upstream{ring: ring}}) do
    {:ok, elem(ring, advance(id, tuple_size(ring)))}
  end

  def select(%Route{id: id, upstream: %Upstream{ring: ring}}) do
    size = tuple_size(ring)
    cursor = advance(id, size)

    Enum.find_value(0..(size - 1), {:error, :no_healthy_upstream}, fn offset ->
      target = elem(ring, rem(cursor + offset, size))
      if Health.healthy?(id, target), do: {:ok, target}
    end)
  end

  # {position, increment, threshold, reset}: past the last slot the cursor wraps to 0.
  defp advance(route_id, size) do
    :ets.update_counter(Store.balancer(), route_id, {2, 1, size - 1, 0}, {route_id, -1})
  end
end
