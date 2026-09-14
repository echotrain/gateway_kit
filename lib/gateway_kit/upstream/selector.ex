defmodule GatewayKit.Upstream.Selector do
  @moduledoc """
  Chooses the upstream target that serves a request.

  Because `url:` and `targets:` normalize to the same list at load time, the proxy never knows
  how the upstream was written — a single `url:` is just a ring of one, and the balancer's
  cursor over it is always 0.
  """

  alias GatewayKit.Config.{Route, Target}
  alias GatewayKit.Upstream.Balancer

  @spec select(Route.t()) :: {:ok, Target.t()}
  def select(%Route{} = route), do: {:ok, Balancer.select(route)}
end
