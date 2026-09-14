defmodule Mix.Tasks.Upstreams do
  @shortdoc "Starts echo upstreams on every port referenced by a gateway config"

  @moduledoc """
  Development helper: starts a small echo server on every upstream port named in the config so
  the gateway can be exercised end-to-end without real backends.

      mix upstreams --config gateway.yaml
      mix upstreams gateway.yaml

  Every path answers with a JSON echo of the request (method, path, query, headers, body) and an
  `x-upstream-port` header; `/healthz` answers `{"status":"ok"}`.
  """

  use Mix.Task

  alias GatewayKit.CLI
  alias GatewayKit.Config
  alias GatewayKit.Config.Loader

  @impl Mix.Task
  def run(args) do
    case CLI.config_path(args, "upstreams") do
      {:ok, path} -> start(path)
      {:error, message} -> Mix.raise(message)
    end
  end

  defp start(path) do
    Mix.Task.run("app.config")
    {:ok, _apps} = Application.ensure_all_started([:bandit, :jason])

    path = Loader.resolve_path(path: path)

    case Loader.load(path) do
      {:ok, config} -> serve(upstream_ports(config))
      {:error, reason} -> Mix.raise(Loader.format_error(path, reason))
    end
  end

  defp upstream_ports(%Config{routes: routes}) do
    routes
    |> Enum.flat_map(fn route -> Enum.map(route.upstream.targets, & &1.uri.port) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp serve(ports) do
    for port <- ports do
      {:ok, _pid} = Bandit.start_link(plug: {__MODULE__.Echo, port}, port: port, startup_log: false)
      Mix.shell().info("Echo upstream listening on http://127.0.0.1:#{port}")
    end

    Process.sleep(:infinity)
  end

  defmodule Echo do
    @moduledoc false
    @behaviour Plug

    import Plug.Conn

    @impl Plug
    def init(port), do: port

    @impl Plug
    def call(%Plug.Conn{path_info: ["healthz"]} = conn, port), do: json(conn, port, %{status: "ok"})

    def call(%Plug.Conn{} = conn, port) do
      {:ok, body, conn} = read_body(conn)

      json(conn, port, %{
        method: conn.method,
        path: conn.request_path,
        query: conn.query_string,
        headers: Map.new(conn.req_headers),
        body: body,
        port: port
      })
    end

    defp json(conn, port, body) do
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("x-upstream-port", Integer.to_string(port))
      |> send_resp(200, Jason.encode!(body))
    end
  end
end
