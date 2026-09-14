defmodule GatewayKit.Stage do
  @moduledoc """
  The contract every pipeline stage implements.

  A stage is *wrapping* middleware: `call/2` receives the context and a `next` function and
  decides whether — and when — to invoke it. That lets one stage express behaviour on both sides
  of the upstream call (a circuit breaker checks state, calls, then records the outcome; retry
  loops around the call; a response transform rewrites what comes back) without leaking any of
  it into the proxy.

  `enabled?/1` is evaluated **once, at config load**. A stage that returns `false` for a route is
  left out of that route's closure entirely, so a route without auth pays nothing for auth — not
  a branch, not a nil check.

  Adding a config feature is: implement this behaviour, add the module to
  `GatewayKit.Pipeline.stages/0` in the right position. Nothing else changes.
  """

  alias GatewayKit.Config.Route
  alias GatewayKit.Context

  @typedoc "The rest of the pipeline, innermost stage last."
  @type next :: (Context.t() -> Context.t())

  @doc "Whether this stage participates in the given route's pipeline."
  @callback enabled?(Route.t()) :: boolean()

  @doc "Runs the stage. Call `next.(ctx)` to continue; return without calling it to short-circuit."
  @callback call(Context.t(), next()) :: Context.t()
end
