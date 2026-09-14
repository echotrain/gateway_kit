defmodule GatewayKit.Router do
  @moduledoc """
  Longest-prefix, segment-aligned route matching with method filtering.

  * A route path matches a request when its segments are a prefix of the request's segments, so
    `/api/users` matches `/api/users` and `/api/users/42` but **not** `/api/userspace`.
  * The most specific route that matches both path and method wins. Routes with the same length
    keep their config order, so overlapping routes are resolved predictably.
  * If some route matches the path but none allow the method, the result is
    `{:error, {:method_not_allowed, allowed}}` so the endpoint can answer 405 with an `Allow`
    header (RFC 7231 §6.5.5) instead of a misleading 404.
  """

  alias GatewayKit.Config.Route

  defstruct routes: []

  @type t :: %__MODULE__{routes: [Route.t()]}

  @type match ::
          {:ok, Route.t(), suffix :: [String.t()]}
          | {:error, :not_found}
          | {:error, {:method_not_allowed, [String.t()]}}

  @doc "Builds a router; routes are ordered longest prefix first, stable within equal lengths."
  @spec new([Route.t()]) :: t()
  def new(routes) do
    %__MODULE__{routes: Enum.sort_by(routes, &length(&1.segments), :desc)}
  end

  @doc "Matches a request `method` and `path_info` against the routing table."
  @spec match(t(), String.t(), [String.t()]) :: match()
  def match(%__MODULE__{routes: routes}, method, path_info) do
    candidates = Enum.filter(routes, &List.starts_with?(path_info, &1.segments))

    case Enum.find(candidates, &(method in &1.methods)) do
      %Route{segments: segments} = route -> {:ok, route, Enum.drop(path_info, length(segments))}
      nil when candidates == [] -> {:error, :not_found}
      nil -> {:error, {:method_not_allowed, allowed_methods(candidates)}}
    end
  end

  defp allowed_methods(routes) do
    routes
    |> Enum.flat_map(& &1.methods)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
