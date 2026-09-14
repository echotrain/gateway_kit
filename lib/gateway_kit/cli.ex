defmodule GatewayKit.CLI do
  @moduledoc """
  Command-line argument handling shared by the `mix gateway` and `mix upstreams` tasks.

  The config path may be given as `--config PATH` or as a bare positional `PATH`. Anything
  else — an unknown option, a second path — is an error: silently falling back to the default
  file would start the gateway with a config the operator did not ask for.
  """

  @spec config_path([String.t()], String.t()) :: {:ok, String.t() | nil} | {:error, String.t()}
  def config_path(argv, task) do
    {opts, positional, invalid} = OptionParser.parse(argv, strict: [config: :string])
    paths = Enum.reject([opts[:config] | positional], &is_nil/1)

    cond do
      invalid != [] -> {:error, "unknown option #{invalid |> hd() |> elem(0)}. #{usage(task)}"}
      length(paths) > 1 -> {:error, "expected one config path, got #{inspect(paths)}. #{usage(task)}"}
      true -> {:ok, List.first(paths)}
    end
  end

  defp usage(task), do: "Usage: mix #{task} [--config PATH | PATH]"
end
