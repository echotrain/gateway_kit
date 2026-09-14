defmodule GatewayKit.Config.Loader do
  @moduledoc """
  Resolves where the gateway config lives, reads it, parses the YAML, and validates it.

  Path resolution order: `--config` flag (stored in the `:config_path` application env by
  `mix gateway`) → `GATEWAY_CONFIG` environment variable → `./gateway.yaml`.

  Every failure is a tagged reason that `format_error/2` renders as a human-readable report —
  a malformed config must never surface as a stacktrace.
  """

  require Logger

  alias GatewayKit.Config
  alias GatewayKit.Config.{Error, Validator}

  @default_path "gateway.yaml"
  @env_var "GATEWAY_CONFIG"

  @type reason :: {:file, File.posix()} | {:yaml, String.t()} | {:invalid, [Error.t()]}

  @doc "Resolves the config path: explicit `:path` → `:config_path` app env → `$GATEWAY_CONFIG` → `./gateway.yaml`."
  @spec resolve_path(keyword()) :: String.t()
  def resolve_path(opts \\ []) do
    opts[:path] || Application.get_env(:gateway_kit, :config_path) || System.get_env(@env_var) || @default_path
  end

  @doc "Reads, parses, and validates the YAML config at `path`."
  @spec load(String.t()) :: {:ok, Config.t()} | {:error, reason()}
  def load(path) do
    with {:ok, contents} <- read_file(path),
         {:ok, raw} <- parse_yaml(contents),
         {:ok, config} <- validate(raw) do
      log_warnings(config, path)
      {:ok, config}
    end
  end

  @doc "Renders a load failure as a report suitable for stderr."
  @spec format_error(String.t(), reason()) :: String.t()
  def format_error(path, {:file, posix}) do
    "Could not read gateway config (#{path}): #{:file.format_error(posix)}"
  end

  def format_error(path, {:yaml, message}) do
    "Could not parse gateway config (#{path}):\n  #{message}"
  end

  def format_error(path, {:invalid, errors}), do: Error.format_report(path, errors)

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, posix} -> {:error, {:file, posix}}
    end
  end

  defp parse_yaml(contents) do
    case YamlElixir.read_from_string(contents) do
      {:ok, raw} -> {:ok, raw}
      {:error, exception} -> {:error, {:yaml, Exception.message(exception)}}
    end
  end

  defp validate(raw) do
    case Validator.validate(raw) do
      {:ok, config} -> {:ok, config}
      {:error, errors} -> {:error, {:invalid, errors}}
    end
  end

  defp log_warnings(%Config{warnings: warnings}, path) do
    Enum.each(warnings, fn %Error{path: key, message: message} ->
      Logger.warning("Gateway config (#{path}): #{key} #{message}")
    end)
  end
end
