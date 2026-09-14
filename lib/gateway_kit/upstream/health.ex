defmodule GatewayKit.Upstream.Health do
  @moduledoc """
  Upstream health state: one ETS row per `{route_id, target_url}` that is currently unhealthy.

  Absence means healthy. Routes without a health check never write here, and consulting the
  table is a single `:ets.member/2` on the request path.
  """

  alias GatewayKit.Config.Target
  alias GatewayKit.Store

  @spec healthy?(term(), Target.t()) :: boolean()
  def healthy?(route_id, %Target{url: url}), do: not :ets.member(Store.upstream_health(), {route_id, url})

  @spec mark(term(), Target.t(), :healthy | :unhealthy) :: :ok
  def mark(route_id, %Target{url: url}, :unhealthy) do
    :ets.insert(Store.upstream_health(), {{route_id, url}, :unhealthy})
    :ok
  end

  def mark(route_id, %Target{url: url}, :healthy) do
    :ets.delete(Store.upstream_health(), {route_id, url})
    :ok
  end
end
