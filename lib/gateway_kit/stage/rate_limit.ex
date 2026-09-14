defmodule GatewayKit.Stage.RateLimit do
  @moduledoc """
  Enforces the route's rate-limit policy, keyed per client IP or globally.

  * `per: "ip"` uses the transport-level peer address only. `X-Forwarded-For` is
    client-controlled; honouring it without a trusted-proxy allowlist would be a one-header
    bypass.
  * Allowed responses carry `x-ratelimit-limit`, `x-ratelimit-remaining` and `x-ratelimit-reset`
    (seconds). A rejected request gets a 429 with `retry-after` plus the same headers.
  * This stage wraps retry, so retries never consume quota: the client made one request.
  """

  @behaviour GatewayKit.Stage

  alias GatewayKit.Config.RateLimit, as: Policy
  alias GatewayKit.Config.Route
  alias GatewayKit.{Context, RateLimit}
  alias GatewayKit.Context.{Request, Response}

  @impl GatewayKit.Stage
  def enabled?(%Route{rate_limit: %Policy{}}), do: true
  def enabled?(%Route{rate_limit: nil}), do: false

  @impl GatewayKit.Stage
  def call(%Context{route: %Route{id: id, rate_limit: policy}, request: request} = ctx, next) do
    key = {id, bucket(policy.per, request)}

    case RateLimit.check(policy, key, System.system_time(:millisecond)) do
      {:allow, info} -> ctx |> next.() |> put_headers(info)
      {:deny, info} -> reject(ctx, info)
    end
  end

  defp bucket(:ip, %Request{client_ip: client_ip}), do: client_ip
  defp bucket(:global, %Request{}), do: :global

  defp reject(ctx, %{reset_after_ms: reset_after_ms} = info) do
    retry_after = seconds(reset_after_ms)
    body = %{error: "rate_limit_exceeded", retry_after: retry_after}

    Context.halt(ctx, 429, body, [{"retry-after", Integer.to_string(retry_after)} | headers(info)])
  end

  defp put_headers(%Context{response: %Response{headers: existing} = response} = ctx, info) do
    %{ctx | response: %{response | headers: existing ++ headers(info)}}
  end

  defp headers(%{limit: limit, remaining: remaining, reset_after_ms: reset_after_ms}) do
    [
      {"x-ratelimit-limit", Integer.to_string(limit)},
      {"x-ratelimit-remaining", Integer.to_string(remaining)},
      {"x-ratelimit-reset", Integer.to_string(seconds(reset_after_ms))}
    ]
  end

  # Round up: telling a client to wait 0s when 900ms remain would only produce another 429.
  defp seconds(ms), do: div(ms + 999, 1_000)
end
