defmodule GatewayKit.Config.Auth do
  @moduledoc """
  Authentication policy. Only `api_key` exists today; the `type` field is what makes `bearer`
  or `jwt` additive later. `header` is stored lowercased to match `Plug.Conn` request headers.
  """

  defstruct [:type, :header, keys: []]

  @type t :: %__MODULE__{type: :api_key, header: String.t(), keys: [String.t(), ...]}
end
