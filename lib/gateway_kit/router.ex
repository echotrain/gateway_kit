defmodule GatewayKit.Router do
  @moduledoc """
  Longest-prefix, segment-aligned route matching with method filtering.

  * A route path matches a request when its segments are a prefix of the request's segments, so
    `/api/users` matches `/api/users` and `/api/users/42` but **not** `/api/userspace`.
  * The **longest** matching prefix decides. Routes of that same length keep their config order
    and the first one that accepts the method wins, so one path may be split across routes by
    method (`/api/orders` `GET` → A, `PUT` → B).
  * If the longest matching prefix accepts other methods but not this one, the result is
    `{:error, {:method_not_allowed, allowed}}` so the endpoint can answer 405 with an `Allow`
    header (RFC 7231 §6.5.5). A shorter route that would accept the method is never consulted:
    `POST /api/users` against `/api/users [GET]` is a 405 even if `/api [POST]` exists.
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
    case Enum.filter(routes, &List.starts_with?(path_info, &1.segments)) do
      [] ->
        {:error, :not_found}

      [%Route{segments: segments} | _rest] = candidates ->
        match_longest(candidates, length(segments), method, path_info)
    end
  end

  # `candidates` are sorted longest first, so the routes sharing the first one's depth lead the list.
  defp match_longest(candidates, depth, method, path_info) do
    longest = Enum.take_while(candidates, &(length(&1.segments) == depth))

    case Enum.find(longest, &(method in &1.methods)) do
      %Route{} = route -> {:ok, route, Enum.drop(path_info, depth)}
      nil -> {:error, {:method_not_allowed, allowed_methods(longest)}}
    end
  end

  defp allowed_methods(routes) do
    routes
    |> Enum.flat_map(& &1.methods)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
