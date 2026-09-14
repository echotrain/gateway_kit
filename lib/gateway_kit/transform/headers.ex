defmodule GatewayKit.Transform.Headers do
  @moduledoc """
  Applies a transform's `remove` and `add` header rules.

  Names are compared case-insensitively by construction: the config lowercases them at load time
  and both the HTTP server and client hand us lowercase names. `add` *sets* a header — an
  existing header of the same name is replaced rather than duplicated — so applying the same
  transform twice is idempotent.
  """

  alias GatewayKit.Config.Transform
  alias GatewayKit.Context
  alias GatewayKit.Transform.Interpolate

  @type headers :: [{String.t(), String.t()}]

  @spec transform(headers(), Transform.t(), Context.t()) :: headers()
  def transform(headers, %Transform{add_headers: add, remove_headers: remove}, %Context{} = ctx) do
    added = Enum.map(add, fn {name, value} -> {name, Interpolate.resolve(value, ctx)} end)
    dropped = remove ++ Enum.map(added, &elem(&1, 0))

    Enum.reject(headers, fn {name, _value} -> name in dropped end) ++ added
  end
end
