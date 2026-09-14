defmodule GatewayKit.Config.HealthCheck do
  @moduledoc "Active health-check policy for a route's upstream targets."

  defstruct [:path, interval_ms: 30_000, unhealthy_threshold: 3]

  @type t :: %__MODULE__{
          path: String.t(),
          interval_ms: pos_integer(),
          unhealthy_threshold: pos_integer()
        }
end
