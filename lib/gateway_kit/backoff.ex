defmodule GatewayKit.Backoff do
  @moduledoc """
  Delay between retry attempts.

  * `fixed` — always `initial_delay`.
  * `exponential` — `initial_delay × 2^n` for the n-th retry (0-based): 1s, 2s, 4s, …

  Jitter is deliberately absent: it matters when many clients retry in lockstep against one
  upstream, which is worth adding once the gateway fans out at scale, not before.
  """

  alias GatewayKit.Config.Retry

  @doc "Milliseconds to wait after the `failed_attempt`-th attempt (1-based) before the next one."
  @spec delay_ms(Retry.t(), pos_integer()) :: non_neg_integer()
  def delay_ms(%Retry{backoff: :fixed, initial_delay_ms: delay}, _failed_attempt), do: delay

  def delay_ms(%Retry{backoff: :exponential, initial_delay_ms: delay}, failed_attempt) do
    delay * Integer.pow(2, failed_attempt - 1)
  end
end
