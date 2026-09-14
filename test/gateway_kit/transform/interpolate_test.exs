defmodule GatewayKit.Transform.InterpolateTest do
  use ExUnit.Case, async: true

  alias GatewayKit.Config.{Route, Transform}
  alias GatewayKit.Context
  alias GatewayKit.Context.Request
  alias GatewayKit.Transform.Interpolate

  setup do
    ctx = %Request{} |> Context.new(%Route{id: 1, path: "/api/legacy"}) |> Context.assign(:body, %{"k" => "v"})
    %{ctx: ctx}
  end

  describe "GatewayKit.Transform.Interpolate.resolve/2" do
    test "every declared variable has a resolving clause", %{ctx: ctx} do
      for variable <- Transform.variables() do
        assert Interpolate.resolve({:var, variable}, ctx) != nil, "#{variable} did not resolve"
      end
    end

    test "literals pass through untouched", %{ctx: ctx} do
      assert Interpolate.resolve({:literal, "$looks_dynamic"}, ctx) == "$looks_dynamic"
    end

    test "$request_time is the request's start in ISO-8601 UTC", %{ctx: ctx} do
      assert Interpolate.resolve({:var, "$request_time"}, ctx) == DateTime.to_iso8601(ctx.started_at)
      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(Interpolate.resolve({:var, "$response_time"}, ctx))
    end

    test "$route_path and $body read from the context", %{ctx: ctx} do
      assert Interpolate.resolve({:var, "$route_path"}, ctx) == "/api/legacy"
      assert Interpolate.resolve({:var, "$body"}, ctx) == %{"k" => "v"}
    end
  end
end
