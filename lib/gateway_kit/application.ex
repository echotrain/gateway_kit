defmodule GatewayKit.Application do
  @moduledoc """
  OTP application entry point.

  Supervision tree (`:one_for_one`):

      GatewayKit.Supervisor
      ├─ GatewayKit.Store                       # ETS owner — started first, before any reader
      ├─ {Finch, name: GatewayKit.Finch}        # pooled upstream HTTP client
      ├─ GatewayKit.Upstream.HealthSupervisor   # DynamicSupervisor for active health checks
      └─ GatewayKit.Server                      # Bandit + Endpoint for the loaded config

  The config is loaded **before** the tree starts. A malformed config prints a report to stderr
  and exits non-zero — it never becomes a supervisor crash with a stacktrace. Setting
  `config :gateway_kit, serve: false` (the test environment) skips the server so tests can boot
  their own instances on ephemeral ports.
  """

  use Application

  alias GatewayKit.Config.Loader

  # Time allowed to establish a TCP connection to an upstream. This is deliberately separate from the
  # per-route request timeout (which bounds the response), matching Envoy/Kong "connect_timeout" semantics.
  @connect_timeout_ms 5_000

  @impl Application
  def start(_type, _args) do
    children =
      [
        GatewayKit.Store,
        {Finch, name: GatewayKit.Finch, pools: finch_pools()},
        GatewayKit.Upstream.HealthSupervisor
      ] ++ server_children()

    Supervisor.start_link(children, strategy: :one_for_one, name: GatewayKit.Supervisor)
  end

  defp finch_pools do
    %{default: [size: 50, conn_opts: [transport_opts: [timeout: @connect_timeout_ms]]]}
  end

  defp server_children do
    if Application.get_env(:gateway_kit, :serve, true), do: [{GatewayKit.Server, config: load_config!()}], else: []
  end

  defp load_config! do
    path = Loader.resolve_path()

    case Loader.load(path) do
      {:ok, config} ->
        config

      {:error, reason} ->
        IO.puts(:stderr, Loader.format_error(path, reason))
        System.halt(1)
    end
  end
end
