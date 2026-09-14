defmodule GatewayKit.Config do
  @moduledoc """
  A validated, fully-resolved gateway configuration.

  Every route is self-contained by the time it lives here: global defaults (`global_timeout`,
  `global_rate_limit`) have already been folded into each `Route`, so nothing on the request path
  ever has to fall back to a global value.
  """

  alias GatewayKit.Config.{Error, RateLimit, Route}

  defstruct port: nil, global_timeout_ms: nil, global_rate_limit: nil, routes: [], warnings: []

  @type t :: %__MODULE__{
          port: 1..65_535,
          global_timeout_ms: pos_integer(),
          global_rate_limit: RateLimit.t() | nil,
          routes: [Route.t()],
          warnings: [Error.t()]
        }
end
