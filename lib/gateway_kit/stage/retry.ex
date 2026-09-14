defmodule GatewayKit.Stage.Retry do
  @moduledoc """
  Re-runs the upstream call when it fails in a way that is safe to replay.

  `attempts` is the **total** number of attempts (1 initial + `attempts - 1` retries). An attempt
  is retried when:

  * the upstream answered with a status listed in `on`; or
  * the upstream was never reached — connection refused, unknown host, unreachable network.

  A **timeout is never retried**. The request may have executed; replaying a `POST` that already
  created an order is worse than a 504. (Finch reports connect and response timeouts with the same
  `:timeout` reason, so the conservative reading applies to both.)

  Each attempt starts from the original context — the failed attempt's response and error are
  discarded — and the route timeout applies **per attempt**. This stage sits inside rate limiting
  and the circuit breaker, so retries consume no quota and count as one breaker outcome.
  """

  @behaviour GatewayKit.Stage

  require Logger

  alias GatewayKit.Backoff
  alias GatewayKit.Config.{Retry, Route}
  alias GatewayKit.Context
  alias GatewayKit.Context.Response

  # Transport failures that prove the request never reached the upstream.
  @replayable [:econnrefused, :nxdomain, :ehostunreach, :enetunreach]

  @impl GatewayKit.Stage
  def enabled?(%Route{retry: %Retry{}}), do: true
  def enabled?(%Route{retry: nil}), do: false

  @impl GatewayKit.Stage
  def call(%Context{route: %Route{retry: retry}} = ctx, next), do: attempt(ctx, next, retry, 1)

  defp attempt(ctx, next, %Retry{attempts: max_attempts} = retry, attempt) do
    result = next.(ctx)

    if attempt < max_attempts and retryable?(result, retry) do
      delay = Backoff.delay_ms(retry, attempt)

      Logger.info(
        "Retrying #{ctx.request.method} #{ctx.request.path} in #{delay}ms (attempt #{attempt + 1}/#{max_attempts})"
      )

      Process.sleep(delay)
      attempt(ctx, next, retry, attempt + 1)
    else
      Context.assign(result, :attempts, attempt)
    end
  end

  # The upstream answered: retry only on the configured statuses.
  defp retryable?(%Context{halted?: false, response: %Response{status: status}}, %Retry{on: statuses}) do
    status in statuses
  end

  # The gateway generated the response: only a failure to reach the upstream is safe to replay.
  defp retryable?(%Context{halted?: true, error: error}, _retry), do: error in @replayable
end
