defmodule GatewayKit.Config.Error do
  @moduledoc """
  A single configuration problem, located by its dotted path (e.g. `routes[1].rate_limit.window`).

  The same struct is used for fatal validation errors and for non-fatal warnings (unknown keys).
  """

  defstruct [:path, :message]

  @type t :: %__MODULE__{path: String.t(), message: String.t()}

  @spec new(String.t(), String.t()) :: t()
  def new(path, message), do: %__MODULE__{path: path, message: message}

  @doc """
  Renders errors as an aligned, human-readable report:

      Invalid gateway config (examples/invalid.yaml):
        routes[1].rate_limit.window   expected a duration like "60s", got: 60
        gateway.port                  expected an integer 1..65535, got: "8080"
  """
  @spec format_report(String.t(), [t()]) :: String.t()
  def format_report(source, errors) do
    width = errors |> Enum.map(&String.length(&1.path)) |> Enum.max(fn -> 0 end)
    lines = Enum.map(errors, &("  " <> String.pad_trailing(&1.path, width + 3) <> &1.message))

    Enum.join(["Invalid gateway config (#{source}):" | lines], "\n")
  end
end
