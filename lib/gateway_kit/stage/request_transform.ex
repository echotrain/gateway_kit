defmodule GatewayKit.Stage.RequestTransform do
  @moduledoc """
  Rewrites the request before it is forwarded: header add/remove, and an optional JSON body
  restructure.

  The body is decoded **only** when a mapping is configured, and only when it parses as a JSON
  object; anything else (non-JSON, an array, an empty `GET` body) is forwarded untouched — the
  gateway never corrupts a body it cannot read. The proxy drops the inbound `content-length`,
  so the client library recomputes it from the transformed bytes.
  """

  @behaviour GatewayKit.Stage

  alias GatewayKit.Config.{Route, Transform}
  alias GatewayKit.Context
  alias GatewayKit.Context.Request
  alias GatewayKit.Transform.{BodyMapping, Headers}

  @impl GatewayKit.Stage
  def enabled?(%Route{request_transform: %Transform{}}), do: true
  def enabled?(%Route{request_transform: nil}), do: false

  @impl GatewayKit.Stage
  def call(%Context{route: %Route{request_transform: transform}, request: request} = ctx, next) do
    request =
      request
      |> transform_headers(transform, ctx)
      |> transform_body(transform.body, ctx)

    next.(%{ctx | request: request})
  end

  defp transform_headers(%Request{headers: headers} = request, transform, ctx) do
    %{request | headers: Headers.transform(headers, transform, ctx)}
  end

  defp transform_body(request, nil, _ctx), do: request

  defp transform_body(%Request{body: body} = request, {:mapping, mapping}, ctx) do
    case Jason.decode(body) do
      {:ok, %{} = source} -> %{request | body: Jason.encode!(BodyMapping.restructure(mapping, source, ctx))}
      _not_a_json_object -> request
    end
  end
end
