defmodule GatewayKit.Upstream.HealthMonitor do
  @moduledoc """
  Active health checks for one route's targets.

  Every `interval`, each target's `health_check.path` is probed with a `GET`. A target is marked
  unhealthy after `unhealthy_threshold` **consecutive** failures (a non-2xx answer or a transport
  error) and healthy again after a **single** success — recover fast, fail slow. Only transitions
  are logged.

  Monitors run under the gateway instance's supervisor (`GatewayKit.Server`), so they start and
  stop with the instance. `check_now/1` runs one probe round synchronously; tests drive the
  monitor that way rather than waiting on the timer.
  """

  use GenServer

  require Logger

  alias GatewayKit.Config.{HealthCheck, Route, Target}
  alias GatewayKit.Upstream.Health

  @type state :: %{route: Route.t(), failures: %{String.t() => non_neg_integer()}}

  @spec child_spec(Route.t()) :: Supervisor.child_spec()
  def child_spec(%Route{id: id} = route) do
    %{id: {__MODULE__, id}, start: {__MODULE__, :start_link, [route]}}
  end

  @spec start_link(Route.t()) :: GenServer.on_start()
  def start_link(%Route{} = route), do: GenServer.start_link(__MODULE__, route)

  @doc "Probes every target once, synchronously, and applies the results."
  @spec check_now(GenServer.server()) :: :ok
  def check_now(monitor), do: GenServer.call(monitor, :check)

  @impl GenServer
  def init(%Route{} = route) do
    schedule(route)
    {:ok, %{route: route, failures: %{}}}
  end

  @impl GenServer
  def handle_call(:check, _from, state), do: {:reply, :ok, probe_all(state)}

  @impl GenServer
  def handle_info(:check, %{route: route} = state) do
    schedule(route)
    {:noreply, probe_all(state)}
  end

  defp schedule(%Route{health_check: %HealthCheck{interval_ms: interval_ms}}) do
    Process.send_after(self(), :check, interval_ms)
  end

  defp probe_all(%{route: route} = state) do
    Enum.reduce(route.upstream.targets, state, fn target, acc -> record(acc, target, probe(route, target)) end)
  end

  defp probe(%Route{health_check: %HealthCheck{path: path} = check, upstream: upstream}, %Target{uri: %URI{} = uri}) do
    url = URI.to_string(%URI{uri | path: uri.path <> path})
    timeout = min(upstream.timeout_ms, check.interval_ms)

    case Finch.request(Finch.build(:get, url), GatewayKit.Finch, receive_timeout: timeout, request_timeout: timeout) do
      {:ok, %Finch.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Finch.Response{status: status}} -> {:error, {:status, status}}
      {:error, %{reason: reason}} -> {:error, reason}
    end
  rescue
    error in RuntimeError -> {:error, {:pool, Exception.message(error)}}
  end

  defp record(%{route: route, failures: failures} = state, %Target{url: url} = target, :ok) do
    if not Health.healthy?(route.id, target) do
      Logger.info("Upstream #{url} is healthy again", route: route.path)
      Health.mark(route.id, target, :healthy)
    end

    %{state | failures: Map.put(failures, url, 0)}
  end

  defp record(%{route: route, failures: failures} = state, %Target{url: url} = target, {:error, reason}) do
    count = Map.get(failures, url, 0) + 1

    if count == route.health_check.unhealthy_threshold do
      Logger.warning("Upstream #{url} marked unhealthy after #{count} consecutive failures: #{inspect(reason)}",
        route: route.path
      )

      Health.mark(route.id, target, :unhealthy)
    end

    %{state | failures: Map.put(failures, url, count)}
  end
end
