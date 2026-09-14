defmodule GatewayKit.Upstream.HealthSupervisor do
  @moduledoc """
  `DynamicSupervisor` for active upstream health monitors.

  One monitor process is started per route that configures a `health_check` block. Keeping them
  under a dynamic supervisor (rather than the static application tree) lets a gateway instance
  start and stop its monitors independently of the shared infrastructure.
  """

  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
