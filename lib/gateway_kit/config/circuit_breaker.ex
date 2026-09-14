defmodule GatewayKit.Config.CircuitBreaker do
  @moduledoc """
  Circuit-breaker policy: trip after `threshold` failures within `window_ms`, then reject
  requests for `cooldown_ms` before letting a single trial request through.
  """

  defstruct [:threshold, window_ms: 60_000, cooldown_ms: 30_000]

  @type t :: %__MODULE__{
          threshold: pos_integer(),
          window_ms: pos_integer(),
          cooldown_ms: pos_integer()
        }
end
