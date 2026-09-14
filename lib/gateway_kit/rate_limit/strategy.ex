defmodule GatewayKit.RateLimit.Strategy do
  @moduledoc """
  The contract a rate-limit strategy implements.

  `check/4` records the request and decides in one step. `now_ms` is passed in rather than read
  from the clock so window arithmetic can be tested by advancing time explicitly.
  """

  alias GatewayKit.Config.RateLimit, as: Policy

  @doc "Counts one request against `key` and decides whether it is within `policy`."
  @callback check(table :: atom(), key :: term(), policy :: Policy.t(), now_ms :: integer()) ::
              GatewayKit.RateLimit.decision()
end
