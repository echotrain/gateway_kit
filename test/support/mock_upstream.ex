defmodule GatewayKit.MockUpstream do
  @moduledoc """
  A self-contained mock upstream HTTP server for tests.

  Each instance is a tiny supervision tree — an `Agent` holding the per-instance state (flaky
  counter, health flag, request log) and a Bandit listener bound to an ephemeral loopback port — so
  `async: true` tests can each run their own upstream without port collisions:

      upstream = start_supervised!(MockUpstream)
      MockUpstream.url(upstream)   # => "http://127.0.0.1:54321"

  Endpoints are matched on the *trailing* path segments, so they work whether or not the gateway
  strips a route prefix (`/api/flaky` and `/flaky` both reach the flaky endpoint):

  | Path suffix     | Response                                                                          |
  | --------------- | --------------------------------------------------------------------------------- |
  | `/healthz`      | 200 `{"status":"ok"}`; 503 `{"status":"unhealthy"}` after `set_healthy(pid, false)` |
  | `/canned`       | 200 `{"message":"canned","source":"upstream"}` + `server` / `x-powered-by` headers |
  | `/slow/:ms`     | sleeps `ms` milliseconds, then 200 `{"slept_ms":ms}`                               |
  | `/status/:code` | that status with `{"status":code}`                                                 |
  | `/flaky`        | 503 for the first `flaky_failures` requests (default 2), then 200 `{"attempt":n}`  |
  | anything else   | 200 echo: `{"method","path","query","headers","body"}` (`headers` is a lowercase map) |

  Every response is `application/json` and carries an `x-upstream-port` header with the instance's
  own port, so load-balancing tests can tell targets apart. Instances are `:temporary` children: a
  restarted upstream would bind a different port, so a crash must fail the test rather than hide
  behind a restart. `stop/1` shuts an instance down to simulate an upstream going away.
  """

  @behaviour Plug

  import Plug.Conn

  @typedoc "A request as recorded by `requests/1`."
  @type request :: %{
          method: String.t(),
          path: String.t(),
          query: String.t(),
          headers: %{String.t() => String.t()},
          body: binary()
        }

  @default_flaky_failures 2

  ## Lifecycle

  @doc """
  Child spec for `start_supervised!/2`.

  Options:

    * `:flaky_failures` — how many `/flaky` requests fail before one succeeds (default 2)
    * `:id` — child id; defaults to a unique `{GatewayKit.MockUpstream, ref}` so one test can
      start several instances without naming them
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, {__MODULE__, make_ref()}),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :temporary
    }
  end

  @doc """
  Starts an instance supervisor with the state agent and the listener as children.

  The listener's plug is configured with the agent's pid, so the agent is started first and the
  listener is added once that pid is known. The two are only valid together, and a restarted
  listener would change port, so no restarts are allowed: a crash of either fails loudly.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    supervisor_opts = [strategy: :one_for_all, max_restarts: 0]

    with {:ok, supervisor} <- Supervisor.start_link([state_spec(opts)], supervisor_opts),
         {:ok, _listener} <- start_listener(supervisor) do
      {:ok, supervisor}
    end
  end

  @doc "Stops the instance, after which connections to its port are refused."
  @spec stop(pid()) :: :ok
  def stop(upstream), do: Supervisor.stop(upstream)

  ## Introspection and control

  @doc "The ephemeral port the instance is listening on."
  @spec port(pid()) :: :inet.port_number()
  def port(upstream) do
    {:ok, {_address, port}} = ThousandIsland.listener_info(child(upstream, :listener))
    port
  end

  @doc "The base URL of the instance, e.g. `\"http://127.0.0.1:54321\"`."
  @spec url(pid()) :: String.t()
  def url(upstream), do: "http://127.0.0.1:#{port(upstream)}"

  @doc "Every request the instance has received, oldest first."
  @spec requests(pid()) :: [request()]
  def requests(upstream) do
    upstream |> state() |> Agent.get(&Enum.reverse(&1.requests))
  end

  @doc "Makes `/healthz` answer 200 (`true`) or 503 (`false`)."
  @spec set_healthy(pid(), boolean()) :: :ok
  def set_healthy(upstream, healthy?) when is_boolean(healthy?) do
    upstream |> state() |> Agent.update(&%{&1 | healthy: healthy?})
  end

  @doc "Restarts the `/flaky` failure sequence from the beginning."
  @spec reset_flaky(pid()) :: :ok
  def reset_flaky(upstream) do
    upstream |> state() |> Agent.update(&%{&1 | flaky_attempts: 0})
  end

  ## Plug

  @impl Plug
  def init(opts), do: Keyword.fetch!(opts, :state)

  @impl Plug
  def call(conn, state) do
    {body, conn} = read_full_body(conn, [])

    request = %{
      method: conn.method,
      path: conn.request_path,
      query: conn.query_string,
      headers: Map.new(conn.req_headers),
      body: body
    }

    Agent.update(state, &%{&1 | requests: [request | &1.requests]})

    conn
    |> put_resp_header("content-type", "application/json")
    |> put_resp_header("x-upstream-port", Integer.to_string(get_sock_data(conn).port))
    |> respond(endpoint(Enum.reverse(conn.path_info)), request, state)
  end

  defp respond(conn, :healthz, _request, state) do
    if Agent.get(state, & &1.healthy),
      do: send_json(conn, 200, %{"status" => "ok"}),
      else: send_json(conn, 503, %{"status" => "unhealthy"})
  end

  defp respond(conn, :canned, _request, _state) do
    conn
    |> put_resp_header("server", "mock-upstream")
    |> put_resp_header("x-powered-by", "mock")
    |> send_json(200, %{"message" => "canned", "source" => "upstream"})
  end

  defp respond(conn, {:slow, ms}, _request, _state) do
    # The delay is the behaviour under test here (slow-upstream / timeout tests).
    Process.sleep(ms)
    send_json(conn, 200, %{"slept_ms" => ms})
  end

  defp respond(conn, {:status, code}, _request, _state) do
    send_json(conn, code, %{"status" => code})
  end

  defp respond(conn, :flaky, _request, state) do
    {attempt, failures} =
      Agent.get_and_update(state, fn %{flaky_attempts: attempts} = current ->
        {{attempts + 1, current.flaky_failures}, %{current | flaky_attempts: attempts + 1}}
      end)

    if attempt <= failures,
      do: send_json(conn, 503, %{"error" => "flaky", "attempt" => attempt}),
      else: send_json(conn, 200, %{"attempt" => attempt})
  end

  defp respond(conn, :echo, request, _state), do: send_json(conn, 200, request)

  # Endpoints are recognised by their trailing path segments (the list is reversed).
  defp endpoint(["healthz" | _]), do: :healthz
  defp endpoint(["canned" | _]), do: :canned
  defp endpoint(["flaky" | _]), do: :flaky
  defp endpoint([ms, "slow" | _]), do: integer_endpoint(:slow, ms)
  defp endpoint([code, "status" | _]), do: integer_endpoint(:status, code)
  defp endpoint(_segments), do: :echo

  defp integer_endpoint(name, segment) do
    case Integer.parse(segment) do
      {value, ""} -> {name, value}
      _other -> :echo
    end
  end

  defp send_json(conn, status, payload), do: send_resp(conn, status, Jason.encode!(payload))

  defp read_full_body(conn, acc) do
    case read_body(conn) do
      {:ok, chunk, conn} -> {IO.iodata_to_binary([acc, chunk]), conn}
      {:more, chunk, conn} -> read_full_body(conn, [acc, chunk])
    end
  end

  ## Supervision helpers

  defp state_spec(opts) do
    failures = Keyword.get(opts, :flaky_failures, @default_flaky_failures)
    initial = %{flaky_failures: failures, flaky_attempts: 0, healthy: true, requests: []}

    %{id: :state, start: {Agent, :start_link, [fn -> initial end]}}
  end

  defp start_listener(supervisor) do
    listener = {Bandit, plug: {__MODULE__, state: state(supervisor)}, ip: :loopback, port: 0, startup_log: false}

    case Supervisor.start_child(supervisor, Supervisor.child_spec(listener, id: :listener)) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} ->
        Supervisor.stop(supervisor)
        {:error, reason}
    end
  end

  defp state(supervisor), do: child(supervisor, :state)

  defp child(supervisor, id) do
    {^id, pid, _type, _modules} = List.keyfind(Supervisor.which_children(supervisor), id, 0)
    pid
  end
end
