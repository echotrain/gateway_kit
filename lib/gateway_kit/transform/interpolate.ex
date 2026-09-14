defmodule GatewayKit.Transform.Interpolate do
  @moduledoc """
  Resolves a parsed config value (`{:literal, text}` or `{:var, "$name"}`) for one request.

  One clause per variable. Adding a variable is a one-line change here plus its name in
  `GatewayKit.Config.Transform.variables/0` — the validator rejects unknown names at load time,
  so no unknown `$name` can reach this module.

  | Variable         | Value                                                            |
  | ---------------- | ---------------------------------------------------------------- |
  | `$request_time`  | when the gateway received the request, ISO-8601 UTC              |
  | `$response_time` | now, ISO-8601 UTC (resolved while building the response)         |
  | `$route_path`    | the matched route's configured path                              |
  | `$body`          | the decoded upstream response body (`ctx.assigns.body`)          |
  | `$literal:text`  | parsed at load time into `{:literal, "text"}`                    |

  Timestamps are ISO-8601 rather than epoch millis: self-describing in logs, and never ambiguous
  between seconds and milliseconds.
  """

  alias GatewayKit.Config.{Route, Transform}
  alias GatewayKit.Context

  @spec resolve(Transform.value(), Context.t()) :: term()
  def resolve({:literal, text}, %Context{}), do: text
  def resolve({:var, "$request_time"}, %Context{started_at: started_at}), do: DateTime.to_iso8601(started_at)
  def resolve({:var, "$response_time"}, %Context{}), do: DateTime.to_iso8601(DateTime.utc_now())
  def resolve({:var, "$route_path"}, %Context{route: %Route{path: path}}), do: path
  def resolve({:var, "$body"}, %Context{assigns: assigns}), do: Map.get(assigns, :body)
end
