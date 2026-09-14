defmodule GatewayKit.Transform.EnvelopeTest do
  use ExUnit.Case, async: true

  alias GatewayKit.Config.Route
  alias GatewayKit.Context
  alias GatewayKit.Context.Request
  alias GatewayKit.Transform.Envelope

  describe "GatewayKit.Transform.Envelope.wrap/2" do
    test "substitutes values recursively through maps and lists, keeping other scalars" do
      ctx = %Request{} |> Context.new(%Route{id: 1, path: "/api/legacy"}) |> Context.assign(:body, [1, 2])

      template = %{
        "data" => {:var, "$body"},
        "meta" => %{"route" => {:var, "$route_path"}, "version" => 2, "tags" => [{:literal, "a"}, true]}
      }

      assert Envelope.wrap(template, ctx) == %{
               "data" => [1, 2],
               "meta" => %{"route" => "/api/legacy", "version" => 2, "tags" => ["a", true]}
             }
    end
  end
end
