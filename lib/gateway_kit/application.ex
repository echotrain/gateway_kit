defmodule GatewayKit.Application do
  @moduledoc """
  OTP application entry point.

  Supervision tree (`:one_for_one`):

      GatewayKit.Supervisor
      ├─ GatewayKit.Store                       # ETS owner — started first, before any reader
      ├─ {Finch, name: GatewayKit.Finch}        # pooled upstream HTTP client
      └─ GatewayKit.Upstream.HealthSupervisor   # DynamicSupervisor for active health checks
  """

  use Application

  # Time allowed to establish a TCP connection to an upstream. This is deliberately separate from the
  # per-route request timeout (which bounds the response), matching Envoy/Kong "connect_timeout" semantics.
  @connect_timeout_ms 5_000

  @impl Application
  def start(_type, _args) do
    children = [
      GatewayKit.Store,
      {Finch, name: GatewayKit.Finch, pools: finch_pools()},
      GatewayKit.Upstream.HealthSupervisor
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: GatewayKit.Supervisor)
  end

  defp finch_pools do
    %{default: [size: 50, conn_opts: [transport_opts: [timeout: @connect_timeout_ms]]]}
  end
end
