defmodule GatewayKit.Endpoint do
  @moduledoc """
  The gateway's single Plug — the only module that touches `Plug.Conn`.

  Request flow:

      GET /health  → always answered here, before routing, independent of config
      otherwise    → Router.match → 404 | 405 + Allow | route.pipeline.(Context)

  Routes are compiled into pipelines once, in `init/1` (Bandit calls it at startup), so the
  per-request work is a route lookup and a closure call.
  """

  @behaviour Plug

  import Plug.Conn

  alias GatewayKit.{Config, Context, Pipeline, Router}
  alias GatewayKit.Config.Route
  alias GatewayKit.Context.{Request, Response}

  @type state :: %{router: Router.t(), started_at: integer()}

  @impl Plug
  @spec init(Config.t()) :: state()
  def init(%Config{routes: routes}) do
    router = routes |> Enum.map(&Pipeline.compile/1) |> Router.new()
    %{router: router, started_at: System.monotonic_time(:second)}
  end

  @impl Plug
  @spec call(Plug.Conn.t(), state()) :: Plug.Conn.t()
  def call(%Plug.Conn{method: "GET", path_info: ["health"]} = conn, %{started_at: started_at}) do
    uptime = System.monotonic_time(:second) - started_at
    send_json(conn, 200, %{status: "healthy", uptime_seconds: uptime})
  end

  def call(%Plug.Conn{} = conn, %{router: router}) do
    case Router.match(router, conn.method, conn.path_info) do
      {:ok, route, _suffix} ->
        dispatch(conn, route)

      {:error, :not_found} ->
        send_json(conn, 404, %{error: "not_found"})

      {:error, {:method_not_allowed, allowed}} ->
        conn
        |> put_resp_header("allow", Enum.join(allowed, ", "))
        |> send_json(405, %{error: "method_not_allowed"})
    end
  end

  defp dispatch(conn, %Route{pipeline: pipeline} = route) do
    case read_full_body(conn, []) do
      {:ok, body, conn} ->
        ctx = pipeline.(Context.new(build_request(conn, body, route), route))
        send_response(conn, ctx.response)

      {:error, _reason} ->
        send_json(conn, 400, %{error: "bad_request"})
    end
  end

  # Raw bytes, never `Plug.Parsers`: a proxy forwards what it received. Stages that need JSON
  # decode it themselves, only when a body transform is configured for the route.
  defp read_full_body(conn, acc) do
    case read_body(conn) do
      {:ok, chunk, conn} -> {:ok, IO.iodata_to_binary([acc | chunk]), conn}
      {:more, chunk, conn} -> read_full_body(conn, [acc | chunk])
      {:error, reason} -> {:error, reason}
    end
  end

  # The suffix is derived from the raw request path (not the decoded `path_info`) so
  # percent-encoding survives `strip_prefix` untouched.
  defp build_request(conn, body, %Route{segments: segments}) do
    suffix = conn.request_path |> String.split("/", trim: true) |> Enum.drop(length(segments))

    %Request{
      method: conn.method,
      path: conn.request_path,
      suffix: suffix,
      query: conn.query_string,
      headers: conn.req_headers,
      body: body,
      client_ip: conn.remote_ip |> :inet.ntoa() |> to_string(),
      scheme: to_string(conn.scheme),
      host: List.first(get_req_header(conn, "host")) || conn.host
    }
  end

  defp send_response(conn, %Response{status: status, headers: headers, body: body}) do
    conn
    |> merge_resp_headers(headers)
    |> send_resp(status, body)
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
