defmodule GatewayKit.Config.RateLimit do
  @moduledoc "Rate-limit policy: `requests` per `window_ms`, bucketed `per` client IP or globally."

  defstruct [:requests, :window_ms, strategy: :fixed_window, per: :ip]

  @type strategy :: :fixed_window | :sliding_window
  @type per :: :ip | :global

  @type t :: %__MODULE__{
          requests: pos_integer(),
          window_ms: pos_integer(),
          strategy: strategy(),
          per: per()
        }
end
