defmodule GatewayKit.Config.Target do
  @moduledoc """
  A single upstream server. `uri` is the parsed, normalized form of `url` (no trailing slash on
  the path) so the proxy can build request URLs without re-parsing on every request.
  """

  defstruct [:url, :uri, weight: 1]

  @type t :: %__MODULE__{url: String.t(), uri: URI.t(), weight: pos_integer()}
end
