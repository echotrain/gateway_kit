defmodule GatewayKit.Upstream.Selector do
  @moduledoc """
  Chooses the upstream target that serves a request.

  Because `url:` and `targets:` normalize to the same list at load time, the proxy never knows
  how the upstream was written. Load balancing slots in here without touching the proxy.
  """

  alias GatewayKit.Config.{Route, Target}

  @spec select(Route.t()) :: {:ok, Target.t()}
  def select(%Route{upstream: %{targets: [target | _rest]}}), do: {:ok, target}
end
