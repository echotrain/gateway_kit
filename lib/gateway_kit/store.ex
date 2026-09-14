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

  # Expired rate-limit windows are garbage; one sweep a minute keeps the table bounded by the
  # number of *active* buckets rather than the number of buckets ever seen.
  @sweep_interval_ms 60_000

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

  @doc """
  Deletes rate-limit rows whose expiry has passed.

  Windowed counter rows are `{{key, index}, count, expires_at_ms}` (see
  `GatewayKit.RateLimit.Window`); this is the one place outside that module that relies on the
  layout. Runs on a timer, and is public so tests can drive it with an explicit clock.
  """
  @spec sweep(integer()) :: non_neg_integer()
  def sweep(now_ms) do
    :ets.select_delete(@rate_limits, [{{:_, :_, :"$1"}, [{:<, :"$1", now_ms}], [true]}])
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    Enum.each(@tables, &:ets.new(&1, @table_opts))
    schedule_sweep()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    sweep(System.system_time(:millisecond))
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
