defmodule GatewayKit.Config.Route do
  @moduledoc """
  One configured route, fully resolved.

  * `id` is unique per VM and namespaces the route's ETS state (rate-limit windows, breaker state,
    balancer cursor). This is what lets several gateway instances — one per test — share the
    `GatewayKit.Store` tables without colliding.
  * `segments` is the pre-split `path`, used by the router for segment-aligned prefix matching.
  * `pipeline` is the composed stage closure, filled in by `GatewayKit.Pipeline.compile/1` at boot.
  """

  alias GatewayKit.Config.{Auth, CircuitBreaker, HealthCheck, RateLimit, Retry, Transform, Upstream}

  defstruct [
    :id,
    :path,
    :segments,
    :methods,
    :strip_prefix,
    :upstream,
    :rate_limit,
    :retry,
    :circuit_breaker,
    :auth,
    :request_transform,
    :response_transform,
    :health_check,
    :pipeline
  ]

  @type t :: %__MODULE__{
          id: pos_integer(),
          path: String.t(),
          segments: [String.t()],
          methods: [String.t()],
          strip_prefix: boolean(),
          upstream: Upstream.t(),
          rate_limit: RateLimit.t() | nil,
          retry: Retry.t() | nil,
          circuit_breaker: CircuitBreaker.t() | nil,
          auth: Auth.t() | nil,
          request_transform: Transform.t() | nil,
          response_transform: Transform.t() | nil,
          health_check: HealthCheck.t() | nil,
          pipeline: (GatewayKit.Context.t() -> GatewayKit.Context.t()) | nil
        }
end
