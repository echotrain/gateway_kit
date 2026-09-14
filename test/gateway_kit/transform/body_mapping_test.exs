defmodule GatewayKit.Transform.BodyMappingTest do
  use ExUnit.Case, async: true

  alias GatewayKit.Config.Route
  alias GatewayKit.Context
  alias GatewayKit.Context.Request
  alias GatewayKit.Transform.BodyMapping

  @ctx Context.new(%Request{}, %Route{id: 1, path: "/api/legacy"})

  @mapping [
    {["user", "id"], {:path, ["userId"]}},
    {["user", "name"], {:path, ["profile", "name"]}},
    {["meta", "source"], {:literal, "gateway"}},
    {["meta", "route"], {:var, "$route_path"}}
  ]

  describe "GatewayKit.Transform.BodyMapping.restructure/3" do
    test "restructures into the mapped destinations only" do
      body = %{"userId" => "u1", "profile" => %{"name" => "Ann", "age" => 40}, "extra" => true}

      assert BodyMapping.restructure(@mapping, body, @ctx) == %{
               "user" => %{"id" => "u1", "name" => "Ann"},
               "meta" => %{"source" => "gateway", "route" => "/api/legacy"}
             }
    end

    test "omits destinations whose source is missing" do
      assert BodyMapping.restructure(@mapping, %{"userId" => "u1", "profile" => "not a map"}, @ctx) == %{
               "user" => %{"id" => "u1"},
               "meta" => %{"source" => "gateway", "route" => "/api/legacy"}
             }
    end

    test "a deeper destination wins over a scalar written at the same key" do
      mapping = [{["user"], {:path, ["userId"]}}, {["user", "id"], {:path, ["userId"]}}]

      assert BodyMapping.restructure(mapping, %{"userId" => "u1"}, @ctx) == %{"user" => %{"id" => "u1"}}
    end
  end
end
