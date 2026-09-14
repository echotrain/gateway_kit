defmodule GatewayKit.Config.Retry do
  @moduledoc """
  Retry policy. `attempts` is the **total** number of attempts (1 initial + `attempts - 1`
  retries); `on` lists the upstream status codes that trigger a retry.
  """

  defstruct [:attempts, backoff: :exponential, initial_delay_ms: 100, on: [502, 503, 504]]

  @type backoff :: :fixed | :exponential

  @type t :: %__MODULE__{
          attempts: pos_integer(),
          backoff: backoff(),
          initial_delay_ms: non_neg_integer(),
          on: [100..599]
        }
end
