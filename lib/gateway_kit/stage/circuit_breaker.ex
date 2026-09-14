defmodule GatewayKit.Stage.CircuitBreaker do
  @moduledoc """
  Rejects requests while the route's breaker is open, and records the outcome of every request
  it lets through — both halves of the call in one stage, which is what the wrapping middleware
  shape exists for.

  Sits outside retry and the transforms: a request that exhausted its retries counts as **one**
  failure, and the rejection body keeps the exact shape the spec mandates:
  `503 {"error":"service_unavailable","retry_after":<seconds_remaining>}`.
  """

  @behaviour GatewayKit.Stage

  alias GatewayKit.Breaker
  alias GatewayKit.Config.{CircuitBreaker, Route}
  alias GatewayKit.Context
  alias GatewayKit.Context.Response

  @impl GatewayKit.Stage
  def enabled?(%Route{circuit_breaker: %CircuitBreaker{}}), do: true
  def enabled?(%Route{circuit_breaker: nil}), do: false

  @impl GatewayKit.Stage
  def call(%Context{route: %Route{id: id, circuit_breaker: breaker}} = ctx, next) do
    case Breaker.check(id, breaker, System.system_time(:millisecond)) do
      :allow -> ctx |> next.() |> record(id, breaker)
      {:reject, retry_after_ms} -> reject(ctx, retry_after_ms)
    end
  end

  defp record(%Context{response: %Response{status: status}} = ctx, id, breaker) do
    Breaker.record(id, breaker, outcome(status), System.system_time(:millisecond))
    ctx
  end

  defp outcome(status) when status >= 500, do: :failure
  defp outcome(_status), do: :success

  # Rounded up, and never 0: while a trial is in flight the remaining cooldown is genuinely zero,
  # but "retry in 1s" is better advice than a tight loop of rejections.
  defp reject(ctx, retry_after_ms) do
    retry_after = max(div(retry_after_ms + 999, 1_000), 1)
    body = %{error: "service_unavailable", retry_after: retry_after}

    Context.halt(ctx, 503, body, [{"retry-after", Integer.to_string(retry_after)}])
  end
end
