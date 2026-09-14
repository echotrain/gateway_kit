defmodule GatewayKit.Server do
  @moduledoc """
  One running gateway instance: the health monitors for its routes plus Bandit serving
  `GatewayKit.Endpoint` for a validated config, under one supervisor.

  Several instances can run in one VM (each test boots its own on an ephemeral port), which is
  why the config is passed as plug options rather than read from global state, and why the
  monitors live here rather than in the application tree — they start and stop with the instance.
  """

  use Supervisor

  alias GatewayKit.Config
  alias GatewayKit.Config.{HealthCheck, Route}
  alias GatewayKit.Upstream.HealthMonitor

  @doc """
  Child spec for a gateway instance.

  Options: `:config` (required, a `%GatewayKit.Config{}`), `:port` (defaults to the config's
  port; `0` binds an ephemeral port), `:startup_log` (Bandit's startup log level or `false`).
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: Keyword.get(opts, :id, __MODULE__), start: {__MODULE__, :start_link, [opts]}, type: :supervisor}
  end

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

  @impl Supervisor
  def init(opts) do
    %Config{} = config = Keyword.fetch!(opts, :config)

    listener =
      {Bandit,
       plug: {GatewayKit.Endpoint, config},
       port: Keyword.get(opts, :port, config.port),
       startup_log: Keyword.get(opts, :startup_log, :info)}

    children = monitors(config) ++ [Supervisor.child_spec(listener, id: :listener)]
    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "The TCP port a running instance is bound to."
  @spec port(pid()) :: :inet.port_number()
  def port(server) do
    {:ok, {_address, port}} = ThousandIsland.listener_info(child(server, :listener))
    port
  end

  @doc "The health monitor processes of a running instance, one per health-checked route."
  @spec health_monitors(pid()) :: [pid()]
  def health_monitors(server) do
    for {{HealthMonitor, _route_id}, pid, _type, _modules} <- Supervisor.which_children(server), do: pid
  end

  defp monitors(%Config{routes: routes}) do
    for %Route{health_check: %HealthCheck{}} = route <- routes, do: {HealthMonitor, route}
  end

  defp child(server, id) do
    {^id, pid, _type, _modules} = List.keyfind(Supervisor.which_children(server), id, 0)
    pid
  end
end
