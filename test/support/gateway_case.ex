defmodule GatewayKit.GatewayCase do
  @moduledoc """
  Case template for end-to-end tests that boot a real gateway on an ephemeral port.

      use GatewayKit.GatewayCase, async: true

      test "proxies to the upstream" do
        upstream = start_supervised!(MockUpstream)
        gateway = start_gateway(config([route("/api/echo", MockUpstream.url(upstream))]))

        {:ok, response} = request(gateway, :get, "/api/echo/users", query: "page=2")

        assert response.status == 200
        assert json(response)["query"] == "page=2"
      end

  Configs are string-keyed maps exactly as `YamlElixir` produces them. They are validated through
  `GatewayKit.Config.Validator` and booted as `GatewayKit.Server` children of the test supervisor
  with `port: 0`, so the `gateway.port` in the config is irrelevant and every test gets an isolated
  instance. YAML fixtures may use `${NAME}` placeholders (e.g. `${UPSTREAM_PORT}`) that are
  substituted before parsing.

  Requests go through the test-only `GatewayKit.TestClient` Finch pool started in
  `test/test_helper.exs` — never the gateway's own `GatewayKit.Finch` — so client-side pooling can
  neither mask nor be masked by the behaviour under test.
  """

  use ExUnit.CaseTemplate

  alias GatewayKit.Config.Validator
  alias GatewayKit.Server

  @typedoc "A running gateway as returned by `start_gateway/1`."
  @type gateway :: %{pid: pid(), port: :inet.port_number(), url: String.t(), config: GatewayKit.Config.t()}

  @typedoc "Anything with a base `:url` — a gateway, or a map wrapping a mock upstream's URL."
  @type endpoint :: %{:url => String.t(), optional(atom()) => term()}

  @client GatewayKit.TestClient
  @default_methods ["GET", "POST", "PUT", "DELETE"]
  @placeholder ~r/\$\{([A-Za-z0-9_]+)\}/

  using do
    quote do
      import GatewayKit.GatewayCase

      alias GatewayKit.MockUpstream
    end
  end

  ## Booting gateways

  @doc """
  Validates `raw_config` and starts a gateway from it on an ephemeral port under the test
  supervisor. Raises with the formatted validation errors when the config is invalid.
  """
  @spec start_gateway(map()) :: gateway()
  def start_gateway(raw_config) when is_map(raw_config) do
    config = validate!(raw_config)
    spec = {Server, config: config, port: 0, startup_log: false}
    pid = ExUnit.Callbacks.start_supervised!(spec, id: {Server, make_ref()}, restart: :temporary)
    port = Server.port(pid)

    %{pid: pid, port: port, url: "http://127.0.0.1:#{port}", config: config}
  end

  @doc "Reads a YAML config with `read_yaml!/2` and boots it with `start_gateway/1`."
  @spec start_gateway_from_yaml(Path.t(), map()) :: gateway()
  def start_gateway_from_yaml(path, substitutions \\ %{}) do
    path |> read_yaml!(substitutions) |> start_gateway()
  end

  @doc """
  Reads a YAML file into the raw config map, replacing every `${NAME}` placeholder with the value
  under `NAME` in `substitutions` (string or atom keys; values are stringified). Raises `KeyError`
  for a placeholder without a substitution.
  """
  @spec read_yaml!(Path.t(), map()) :: map()
  def read_yaml!(path, substitutions \\ %{}) do
    substitutions = Map.new(substitutions, fn {name, value} -> {to_string(name), to_string(value)} end)

    path
    |> File.read!()
    |> substitute(substitutions)
    |> YamlElixir.read_from_string!()
  end

  ## Requests

  @doc """
  Sends a request to `endpoint` through the test client.

  Options: `:headers` (list of `{name, value}`), `:body` (binary), `:query` (raw query string
  without the `?`), and `:receive_timeout` (milliseconds, passed to Finch).
  """
  @spec request(endpoint(), atom() | String.t(), String.t(), keyword()) ::
          {:ok, Finch.Response.t()} | {:error, Exception.t()}
  def request(%{url: base_url}, method, path, opts \\ []) do
    url = base_url <> path <> query_suffix(Keyword.get(opts, :query))

    method
    |> Finch.build(url, Keyword.get(opts, :headers, []), Keyword.get(opts, :body))
    |> Finch.request(@client, Keyword.take(opts, [:receive_timeout]))
  end

  @doc "The response body decoded as JSON."
  @spec json(Finch.Response.t()) :: term()
  def json(%Finch.Response{body: body}), do: Jason.decode!(body)

  @doc "The value of the first response header named `name` (case-insensitive), or `nil`."
  @spec header(Finch.Response.t(), String.t()) :: String.t() | nil
  def header(%Finch.Response{headers: headers}, name) do
    case List.keyfind(headers, String.downcase(name), 0) do
      {_name, value} -> value
      nil -> nil
    end
  end

  ## Config builders

  @doc """
  A minimal raw route map: `path`, all four common methods, `strip_prefix: false` and a single
  `upstream.url`. `overrides` are merged on top (shallow, so an `"upstream"` override replaces the
  whole upstream block).
  """
  @spec route(String.t(), String.t(), map()) :: map()
  def route(path, upstream_url, overrides \\ %{}) do
    base = %{
      "path" => path,
      "methods" => @default_methods,
      "strip_prefix" => false,
      "upstream" => %{"url" => upstream_url}
    }

    Map.merge(base, overrides)
  end

  @doc """
  A minimal raw config map: `gateway.port` (ignored by `start_gateway/1`, which binds port 0)
  merged with `gateway_overrides`, plus the given `routes`.
  """
  @spec config([map()], map()) :: map()
  def config(routes, gateway_overrides \\ %{}) when is_list(routes) do
    %{"gateway" => Map.merge(%{"port" => 8080}, gateway_overrides), "routes" => routes}
  end

  ## Private

  defp validate!(raw_config) do
    case Validator.validate(raw_config) do
      {:ok, config} ->
        config

      {:error, errors} ->
        report = Enum.map_join(errors, "\n", fn %{path: path, message: message} -> "  #{path}  #{message}" end)
        raise ArgumentError, "invalid gateway config:\n" <> report
    end
  end

  defp substitute(text, substitutions) do
    Regex.replace(@placeholder, text, fn _match, name -> Map.fetch!(substitutions, name) end)
  end

  defp query_suffix(nil), do: ""
  defp query_suffix(""), do: ""
  defp query_suffix(query), do: "?" <> query
end
