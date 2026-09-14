defmodule Mix.Tasks.Gateway do
  @shortdoc "Starts the gateway: mix gateway --config gateway.yaml"

  @moduledoc """
  Starts the gateway and keeps it running.

      mix gateway --config gateway.yaml
      mix gateway gateway.yaml

  The path given here takes precedence over the `GATEWAY_CONFIG` environment variable, which
  takes precedence over `./gateway.yaml`.
  """

  use Mix.Task

  alias GatewayKit.CLI

  @impl Mix.Task
  def run(args) do
    case CLI.config_path(args, "gateway") do
      {:ok, path} -> start(path)
      {:error, message} -> Mix.raise(message)
    end
  end

  defp start(path) do
    Mix.Task.run("app.config")
    if path, do: Application.put_env(:gateway_kit, :config_path, path)

    Mix.Task.run("run", ["--no-halt"])
  end
end
