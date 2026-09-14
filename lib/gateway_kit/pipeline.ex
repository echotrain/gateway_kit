defmodule GatewayKit.Pipeline do
  @moduledoc """
  Composes a route's enabled stages into a single closure at config-load time.

  `build/2` folds the stage list right-to-left: each stage is wrapped around everything after it,
  and disabled stages are omitted from the closure entirely. The result is one function per
  route with no config interpretation left on the hot path.

  Stage order, outermost first:

      Auth → RateLimit → CircuitBreaker → RequestTransform → ResponseTransform → Retry → Proxy

  The proxy is terminal — it never calls `next`. Adding a config feature is one module
  implementing `GatewayKit.Stage` plus one entry in this list, in the position its semantics
  require.
  """

  alias GatewayKit.Config.Route
  alias GatewayKit.Context

  @stages [
    GatewayKit.Stage.Auth,
    GatewayKit.Stage.RateLimit,
    GatewayKit.Stage.CircuitBreaker,
    GatewayKit.Stage.RequestTransform,
    GatewayKit.Stage.ResponseTransform,
    GatewayKit.Stage.Retry,
    GatewayKit.Stage.Proxy
  ]

  @doc "The stage modules, outermost first."
  @spec stages() :: [module()]
  def stages, do: @stages

  @doc "Attaches the composed pipeline to a route."
  @spec compile(Route.t()) :: Route.t()
  def compile(%Route{} = route), do: %{route | pipeline: build(route)}

  @doc "Builds the closure for `route` from `stages`, omitting stages whose `enabled?/1` is false."
  @spec build(Route.t(), [module()]) :: (Context.t() -> Context.t())
  def build(%Route{} = route, stages \\ @stages) do
    stages
    |> Enum.filter(& &1.enabled?(route))
    |> List.foldr(&Function.identity/1, fn stage, next -> &stage.call(&1, next) end)
  end
end
