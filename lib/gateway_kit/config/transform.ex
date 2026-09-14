defmodule GatewayKit.Config.Transform do
  @moduledoc """
  A request or response transform, pre-parsed at load time so nothing is interpreted per request.

  * Header names are lowercased. `add_headers` values are parsed `value()`s.
  * `body` is `{:mapping, entries}` for request transforms (`destination <- source`, whitelist),
    `{:envelope, template}` for response transforms, or `nil`.

  Every string that starts with `$` is a *dynamic value* and must be one of `variables/0` or a
  `$literal:<text>` escape. Unknown `$names` are a fatal config error: silently forwarding the
  literal text `"$reqest_time"` would be worse than refusing to boot.
  """

  @variables ~w($request_time $response_time $route_path $body)

  defstruct add_headers: [], remove_headers: [], body: nil

  @typedoc "A parsed config value: a fixed string, or a variable resolved per request."
  @type value :: {:literal, String.t()} | {:var, String.t()}

  @typedoc "Where a body-mapping destination is read from: a dotted path in the request body, or a value."
  @type source :: {:path, [String.t(), ...]} | value()

  @type mapping_entry :: {destination :: [String.t(), ...], source()}

  @type body :: {:mapping, [mapping_entry()]} | {:envelope, term()} | nil

  @type t :: %__MODULE__{
          add_headers: [{String.t(), value()}],
          remove_headers: [String.t()],
          body: body()
        }

  @doc "Every dynamic `$variable` the gateway knows how to resolve."
  @spec variables() :: [String.t()]
  def variables, do: @variables
end
