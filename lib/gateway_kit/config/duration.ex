defmodule GatewayKit.Config.Duration do
  @moduledoc """
  Parses human-readable config durations (`"500ms"`, `"30s"`, `"5m"`, `"1h"`) into milliseconds.

  Only non-negative integers with an explicit unit are accepted. Bare numbers are rejected on
  purpose: `window: 60` is ambiguous between seconds and milliseconds, and the schema always
  spells the unit out.
  """

  @units %{"ms" => 1, "s" => 1_000, "m" => 60_000, "h" => 3_600_000}

  @doc """
  Parses a duration string into milliseconds.

  ## Examples

      iex> GatewayKit.Config.Duration.parse("30s")
      {:ok, 30_000}

      iex> GatewayKit.Config.Duration.parse("500ms")
      {:ok, 500}

      iex> GatewayKit.Config.Duration.parse(60)
      :error
  """
  @spec parse(term()) :: {:ok, non_neg_integer()} | :error
  def parse(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {amount, unit} when amount >= 0 -> multiply(amount, String.trim(unit))
      _ -> :error
    end
  end

  def parse(_value), do: :error

  defp multiply(amount, unit) do
    case Map.fetch(@units, unit) do
      {:ok, factor} -> {:ok, amount * factor}
      :error -> :error
    end
  end
end
