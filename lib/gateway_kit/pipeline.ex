defmodule GatewayKit.Pipeline do
  @moduledoc """
  Composes a route's enabled stages into a single closure at config-load time.

  `build/2` folds the stage list right-to-left: each stage is wrapped around everything after it,
  and disabled stages are omitted from the closure entirely. The result is one function per
  route with no config interpretation left on the hot path.

  Stage order, outermost first:

      Auth → RateLimit → CircuitBreaker → RequestTransform → ResponseTransform → Retry → Proxy

  The proxy is terminal — it never calls `next`.
  """

  require Logger

  alias GatewayKit.Config.Route
  alias GatewayKit.Context

  @stages [
    GatewayKit.Stage.Auth,
    GatewayKit.Stage.RateLimit,
    GatewayKit.Stage.Retry,
    GatewayKit.Stage.Proxy
  ]

  # Config features the validator accepts but no stage implements yet. A route using one still
  # boots; the omission is logged once here, never fatal.
  @unimplemented [
    circuit_breaker: "circuit breaking",
    request_transform: "request transformation",
    response_transform: "response transformation",
    health_check: "active health checks"
  ]

  @doc "The stage modules, outermost first."
  @spec stages() :: [module()]
  def stages, do: @stages

  @doc "Attaches the composed pipeline to a route."
  @spec compile(Route.t()) :: Route.t()
  def compile(%Route{} = route) do
    log_unimplemented(route)
    %{route | pipeline: build(route)}
  end

  @doc "Builds the closure for `route` from `stages`, omitting stages whose `enabled?/1` is false."
  @spec build(Route.t(), [module()]) :: (Context.t() -> Context.t())
  def build(%Route{} = route, stages \\ @stages) do
    stages
    |> Enum.filter(& &1.enabled?(route))
    |> List.foldr(&Function.identity/1, fn stage, next -> &stage.call(&1, next) end)
  end

  defp log_unimplemented(%Route{path: path} = route) do
    for {feature, description} <- @unimplemented, Map.fetch!(route, feature) != nil do
      Logger.info("Route #{path}: #{description} is configured but not implemented yet; ignoring")
    end
  end
end
