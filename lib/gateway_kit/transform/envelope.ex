defmodule GatewayKit.Transform.Envelope do
  @moduledoc """
  Builds a response body from an envelope template by recursive substitution.

  The template was parsed at load time: string leaves became `{:literal, _}` / `{:var, _}`
  values, other scalars were kept. Maps and lists are walked; every value is resolved through
  `GatewayKit.Transform.Interpolate`, so `$body` places the decoded upstream body wherever the
  template says.
  """

  alias GatewayKit.Context
  alias GatewayKit.Transform.Interpolate

  @spec wrap(term(), Context.t()) :: term()
  def wrap(%{} = template, %Context{} = ctx), do: Map.new(template, fn {key, value} -> {key, wrap(value, ctx)} end)
  def wrap(template, %Context{} = ctx) when is_list(template), do: Enum.map(template, &wrap(&1, ctx))
  def wrap({:literal, _text} = value, %Context{} = ctx), do: Interpolate.resolve(value, ctx)
  def wrap({:var, _name} = value, %Context{} = ctx), do: Interpolate.resolve(value, ctx)
  def wrap(scalar, %Context{}), do: scalar
end
