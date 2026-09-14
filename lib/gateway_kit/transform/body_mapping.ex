defmodule GatewayKit.Transform.BodyMapping do
  @moduledoc """
  Restructures a decoded JSON request body: `destination.path <- source`.

  This is a **whitelist**: the output contains only the mapped destinations. The config comment
  says "restructure", not "augment", so unmapped fields do not survive. A source path that is
  absent from the body is simply omitted from the output — no phantom `null`s.

  Sources are pre-parsed at load time: `{:path, segments}` reads from the body,
  `{:literal, _}` / `{:var, _}` go through `GatewayKit.Transform.Interpolate`.
  """

  alias GatewayKit.Config.Transform
  alias GatewayKit.Context
  alias GatewayKit.Transform.Interpolate

  @spec restructure([Transform.mapping_entry()], map(), Context.t()) :: map()
  def restructure(mapping, %{} = source, %Context{} = ctx) do
    Enum.reduce(mapping, %{}, fn {destination, spec}, acc ->
      case resolve(spec, source, ctx) do
        nil -> acc
        value -> put_path(acc, destination, value)
      end
    end)
  end

  defp resolve({:path, segments}, source, _ctx), do: fetch_path(source, segments)
  defp resolve(value, _source, ctx), do: Interpolate.resolve(value, ctx)

  defp fetch_path(value, []), do: value
  defp fetch_path(%{} = map, [key | rest]), do: fetch_path(Map.get(map, key), rest)
  defp fetch_path(_other, _segments), do: nil

  defp put_path(map, [key], value), do: Map.put(map, key, value)

  defp put_path(map, [key | rest], value) do
    nested =
      case Map.get(map, key) do
        %{} = existing -> existing
        _other -> %{}
      end

    Map.put(map, key, put_path(nested, rest, value))
  end
end
