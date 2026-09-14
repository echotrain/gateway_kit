defmodule GatewayKit.Server do
  @moduledoc """
  One running gateway instance: Bandit serving `GatewayKit.Endpoint` for a validated config.

  Several instances can run in one VM (each test boots its own on an ephemeral port), which is
  why the config is passed as plug options rather than read from global state.
  """

  alias GatewayKit.Config

  @doc """
  Child spec for a gateway instance.

  Options: `:config` (required, a `%GatewayKit.Config{}`), `:port` (defaults to the config's
  port; `0` binds an ephemeral port), `:startup_log` (Bandit's startup log level or `false`).
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %Config{} = config = Keyword.fetch!(opts, :config)

    bandit_opts = [
      plug: {GatewayKit.Endpoint, config},
      port: Keyword.get(opts, :port, config.port),
      startup_log: Keyword.get(opts, :startup_log, :info)
    ]

    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {Bandit, :start_link, [bandit_opts]},
      type: :supervisor,
      restart: :permanent
    }
  end

  @doc "The TCP port a running instance is bound to."
  @spec port(pid()) :: :inet.port_number()
  def port(pid) do
    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    port
  end
end
