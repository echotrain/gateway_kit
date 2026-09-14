defmodule GatewayKit.Store do
  @moduledoc """
  Owner of every ETS table holding shared, mutable gateway state.

  All request-path state (rate-limit counters, circuit-breaker state, load-balancer cursors,
  upstream health) lives in public ETS tables owned by this supervised process. Stages never go
  through a GenServer on the hot path — they use atomic ETS operations (`:ets.update_counter/4`,
  `:ets.select_replace/2`) directly, so there is no serialization bottleneck and no lost updates
  under concurrent load.

  Tables are created unconditionally in `init/1`: a named table dies with its owner, so a
  conditional `:ets.whereis/1` check would be a race, not a safeguard.
  """

  use GenServer

  @rate_limits :gateway_kit_rate_limits
  @breakers :gateway_kit_breakers
  @balancer :gateway_kit_balancer
  @upstream_health :gateway_kit_upstream_health

  @tables [@rate_limits, @breakers, @balancer, @upstream_health]

  @table_opts [
    :set,
    :named_table,
    :public,
    read_concurrency: true,
    write_concurrency: true,
    decentralized_counters: true
  ]

  @doc "Rate-limit window counters."
  @spec rate_limits() :: atom()
  def rate_limits, do: @rate_limits

  @doc "Circuit-breaker state, one entry per route."
  @spec breakers() :: atom()
  def breakers, do: @breakers

  @doc "Load-balancer round-robin cursors, one entry per route."
  @spec balancer() :: atom()
  def balancer, do: @balancer

  @doc "Upstream health status, one entry per `{route, target}`."
  @spec upstream_health() :: atom()
  def upstream_health, do: @upstream_health

  @doc "Every table owned by the store."
  @spec tables() :: [atom()]
  def tables, do: @tables

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    Enum.each(@tables, &:ets.new(&1, @table_opts))
    {:ok, %{}}
  end
end
