defmodule GatewayKit.RateLimit do
  @moduledoc """
  Rate-limit decisions.

  Dispatches to the strategy module named by the policy. Adding a strategy is one module
  implementing `GatewayKit.RateLimit.Strategy` plus one entry in `@strategies`; the config
  validator already rejects strategy names that are not listed there.
  """

  alias GatewayKit.Config.RateLimit, as: Policy
  alias GatewayKit.RateLimit.{FixedWindow, SlidingWindow}
  alias GatewayKit.Store

  @strategies %{fixed_window: FixedWindow, sliding_window: SlidingWindow}

  @typedoc "What the client is told: the limit, what is left, and when the bucket refills."
  @type info :: %{limit: pos_integer(), remaining: non_neg_integer(), reset_after_ms: non_neg_integer()}

  @type decision :: {:allow, info()} | {:deny, info()}

  @doc "Counts one request against `key` under `policy` at `now_ms` and decides."
  @spec check(Policy.t(), term(), integer()) :: decision()
  def check(%Policy{strategy: strategy} = policy, key, now_ms) do
    Map.fetch!(@strategies, strategy).check(Store.windows(), key, policy, now_ms)
  end
end
