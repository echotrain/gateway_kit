defmodule GatewayKit.Stage.ResponseTransform do
  @moduledoc """
  Rewrites the upstream response on its way back: header add/remove, and an optional envelope
  around the body.

  Only **upstream** responses are transformed. A response the gateway generated itself (a 502,
  a 504, a retry that gave up on a transport error) keeps the uniform `{"error": ...}` shape,
  so clients can always rely on it.

  The envelope applies to any body: JSON is embedded decoded; other readable text is embedded as
  a string; a body that is encoded (`content-encoding`) or not valid UTF-8 cannot be read and is
  passed through untouched. After wrapping, `content-length` is recomputed and `content-type`
  becomes `application/json`.
  """

  @behaviour GatewayKit.Stage

  alias GatewayKit.Config.{Route, Transform}
  alias GatewayKit.Context
  alias GatewayKit.Context.Response
  alias GatewayKit.Transform.{Envelope, Headers}

  @impl GatewayKit.Stage
  def enabled?(%Route{response_transform: %Transform{}}), do: true
  def enabled?(%Route{response_transform: nil}), do: false

  @impl GatewayKit.Stage
  def call(%Context{route: %Route{response_transform: transform}} = ctx, next) do
    case next.(ctx) do
      %Context{halted?: true} = halted ->
        halted

      %Context{response: %Response{} = response} = result ->
        %{result | response: transform(response, transform, result)}
    end
  end

  defp transform(response, %Transform{body: body} = transform, ctx) do
    response
    |> transform_body(body, ctx)
    |> transform_headers(transform, ctx)
  end

  defp transform_headers(%Response{headers: headers} = response, transform, ctx) do
    %{response | headers: Headers.transform(headers, transform, ctx)}
  end

  defp transform_body(response, nil, _ctx), do: response

  defp transform_body(%Response{body: raw, headers: headers} = response, {:envelope, template}, ctx) do
    case readable_body(raw, headers) do
      {:ok, decoded} ->
        wrapped = Jason.encode!(Envelope.wrap(template, Context.assign(ctx, :body, decoded)))
        %{response | body: wrapped, headers: recompute(headers, wrapped)}

      :unreadable ->
        response
    end
  end

  defp readable_body(raw, headers) do
    cond do
      List.keymember?(headers, "content-encoding", 0) -> :unreadable
      match?({:ok, _json}, Jason.decode(raw)) -> Jason.decode(raw)
      String.valid?(raw) -> {:ok, raw}
      true -> :unreadable
    end
  end

  defp recompute(headers, body) do
    Enum.reject(headers, fn {name, _value} -> name in ~w(content-length content-type) end) ++
      [{"content-length", Integer.to_string(byte_size(body))}, {"content-type", "application/json"}]
  end
end
