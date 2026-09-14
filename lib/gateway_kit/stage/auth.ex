defmodule GatewayKit.Stage.Auth do
  @moduledoc """
  `api_key` authentication: the configured header must carry one of the configured keys.

  A missing key and a wrong key produce the *same* 401 body, so the response is not an oracle for
  "does this header name matter". Keys are compared in constant time, and every configured key is
  compared on every request, so timing does not reveal which key (if any) matched.

  `type` is matched explicitly so `bearer` / `jwt` can be added as further clauses without
  touching the existing one.
  """

  @behaviour GatewayKit.Stage

  alias GatewayKit.Config.{Auth, Route}
  alias GatewayKit.Context

  @impl GatewayKit.Stage
  def enabled?(%Route{auth: %Auth{}}), do: true
  def enabled?(%Route{auth: nil}), do: false

  @impl GatewayKit.Stage
  def call(%Context{route: %Route{auth: auth}, request: request} = ctx, next) do
    if authorized?(auth, request.headers) do
      next.(ctx)
    else
      Context.halt(ctx, 401, %{error: "unauthorized"})
    end
  end

  defp authorized?(%Auth{type: :api_key, header: header, keys: keys}, headers) do
    case List.keyfind(headers, header, 0) do
      {_name, presented} -> Enum.reduce(keys, false, &(Plug.Crypto.secure_compare(&1, presented) or &2))
      nil -> false
    end
  end
end
