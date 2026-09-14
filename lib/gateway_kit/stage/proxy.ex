defmodule GatewayKit.Stage.Proxy do
  @moduledoc """
  Terminal stage: forwards the request to a selected upstream target and captures the response.

  Proxy hygiene, in both directions:

  * hop-by-hop headers (`connection`, `keep-alive`, `transfer-encoding`, `upgrade`,
    `proxy-authenticate`, `proxy-authorization`, `te`, `trailer`) plus any header named in the
    `connection` field are stripped — they describe *this* hop, not the end-to-end message;
  * `host` is rewritten to the upstream authority; `content-length` is dropped so the HTTP client
    recomputes it from the body actually sent (which a request transform may have changed);
  * `x-forwarded-for` is appended to, `x-forwarded-proto` / `x-forwarded-host` are set;
  * the query string is preserved; `strip_prefix` rewrites the path, forwarding `/` on an exact match.

  Failures map to gateway errors: a timeout is a 504, anything else that prevented a response
  (refused connection, DNS, pool exhaustion) is a 502. The normalized reason is kept in
  `ctx.error` so the retry stage can tell "never reached the upstream" from "may have executed".
  """

  @behaviour GatewayKit.Stage

  require Logger

  alias GatewayKit.Config.{Route, Target}
  alias GatewayKit.Context
  alias GatewayKit.Context.{Request, Response}
  alias GatewayKit.Upstream.Selector

  @hop_by_hop ~w(connection keep-alive proxy-authenticate proxy-authorization te trailer transfer-encoding upgrade)
  @forwarded ~w(x-forwarded-for x-forwarded-proto x-forwarded-host)
  @rewritten ~w(host content-length)
  @bodyless_methods ~w(GET HEAD OPTIONS TRACE)

  @impl GatewayKit.Stage
  def enabled?(%Route{}), do: true

  @impl GatewayKit.Stage
  def call(%Context{route: route} = ctx, _next) do
    {:ok, target} = Selector.select(route)
    forward(ctx, target)
  end

  defp forward(%Context{route: route, request: request} = ctx, %Target{} = target) do
    timeout = route.upstream.timeout_ms

    request.method
    |> Finch.build(upstream_url(target, route, request), upstream_headers(request, target), upstream_body(request))
    |> send_request(timeout)
    |> handle_result(ctx)
  end

  defp send_request(finch_request, timeout) do
    Finch.request(finch_request, GatewayKit.Finch, receive_timeout: timeout, request_timeout: timeout)
  rescue
    # Finch re-raises pool checkout exhaustion as a RuntimeError; treat it like any other
    # failure to reach the upstream rather than crashing the connection process.
    error in RuntimeError -> {:error, {:pool, Exception.message(error)}}
  end

  defp handle_result({:ok, %Finch.Response{status: status, headers: headers, body: body}}, ctx) do
    Context.respond(ctx, %Response{status: status, headers: strip_hop_by_hop(headers), body: body})
  end

  defp handle_result({:error, %Finch.TransportError{reason: :timeout}}, %Context{route: route} = ctx) do
    Logger.warning("Upstream timed out after #{route.upstream.timeout_ms}ms", route: route.path)

    ctx
    |> Context.put_error(:timeout)
    |> Context.halt(504, %{error: "gateway_timeout"})
  end

  defp handle_result({:error, reason}, %Context{route: route} = ctx) do
    normalized = normalize_error(reason)
    Logger.warning("Upstream request failed: #{inspect(normalized)}", route: route.path)

    ctx
    |> Context.put_error(normalized)
    |> Context.halt(502, %{error: "bad_gateway"})
  end

  # Finch wraps Mint's errors in its own structs; the bare reason (`:econnrefused`, `:nxdomain`,
  # `:closed`, …) is what the retry stage needs to classify the failure.
  defp normalize_error(%Finch.TransportError{reason: reason}), do: reason
  defp normalize_error(%Finch.HTTPError{reason: reason}), do: reason
  defp normalize_error(%Finch.Error{reason: reason}), do: reason
  defp normalize_error(other), do: other

  # -- request building ------------------------------------------------------

  defp upstream_url(%Target{uri: %URI{} = uri}, %Route{strip_prefix: strip_prefix}, %Request{query: query} = request) do
    URI.to_string(%URI{uri | path: uri.path <> forward_path(strip_prefix, request), query: query(query)})
  end

  defp forward_path(true, %Request{suffix: suffix}), do: "/" <> Enum.join(suffix, "/")
  defp forward_path(false, %Request{path: path}), do: path

  defp query(""), do: nil
  defp query(query), do: query

  defp upstream_headers(%Request{headers: headers} = request, %Target{uri: uri}) do
    dropped = @hop_by_hop ++ @forwarded ++ @rewritten ++ connection_tokens(headers)
    kept = Enum.reject(headers, fn {name, _value} -> name in dropped end)

    [{"host", authority(uri)} | forwarded_headers(request) ++ kept]
  end

  defp forwarded_headers(%Request{headers: headers, client_ip: client_ip, scheme: scheme, host: host}) do
    forwarded_for =
      headers
      |> Enum.filter(&(elem(&1, 0) == "x-forwarded-for"))
      |> Enum.map(&elem(&1, 1))
      |> Enum.concat([client_ip])
      |> Enum.join(", ")

    [{"x-forwarded-for", forwarded_for}, {"x-forwarded-proto", scheme}, {"x-forwarded-host", host}]
  end

  defp authority(%URI{host: host, port: port, scheme: scheme}) do
    if port == URI.default_port(scheme), do: host, else: "#{host}:#{port}"
  end

  defp upstream_body(%Request{method: method, body: ""}) when method in @bodyless_methods, do: nil
  defp upstream_body(%Request{body: body}), do: body

  # -- header hygiene --------------------------------------------------------

  defp strip_hop_by_hop(headers) do
    dropped = @hop_by_hop ++ connection_tokens(headers)
    Enum.reject(headers, fn {name, _value} -> name in dropped end)
  end

  # RFC 7230 §6.1: headers listed in `Connection` are hop-by-hop too.
  defp connection_tokens(headers) do
    headers
    |> Enum.filter(&(elem(&1, 0) == "connection"))
    |> Enum.flat_map(fn {_name, value} -> String.split(value, ",") end)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
  end
end
