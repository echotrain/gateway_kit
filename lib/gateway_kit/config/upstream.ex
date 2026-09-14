defmodule GatewayKit.Config.Upstream do
  @moduledoc """
  Where a route forwards to.

  A bare `url:` and a `targets:` list normalize to the same shape — always a list of `Target`s —
  so target selection never has to branch on how the upstream was written.

  `ring` is the target selection ring expanded at load time: for `weighted_round_robin` each
  target appears `weight` times; for `round_robin` each appears once. The balancer only ever
  indexes into it with an atomic cursor.
  """

  alias GatewayKit.Config.Target

  defstruct targets: [], balance: :round_robin, timeout_ms: nil, ring: {}

  @type balance :: :round_robin | :weighted_round_robin

  @type t :: %__MODULE__{
          targets: [Target.t(), ...],
          balance: balance(),
          timeout_ms: pos_integer(),
          ring: tuple()
        }
end
