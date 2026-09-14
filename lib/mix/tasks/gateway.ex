defmodule Mix.Tasks.Gateway do
  @shortdoc "Starts the gateway: mix gateway --config gateway.yaml"

  @moduledoc """
  Starts the gateway and keeps it running.

      mix gateway --config gateway.yaml

  `--config` takes precedence over the `GATEWAY_CONFIG` environment variable, which takes
  precedence over `./gateway.yaml`.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: [config: :string])

    Mix.Task.run("app.config")
    if path = opts[:config], do: Application.put_env(:gateway_kit, :config_path, path)

    Mix.Task.run("run", ["--no-halt"])
  end
end
