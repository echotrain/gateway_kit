defmodule GatewayKit.Transform.HeadersTest do
  use ExUnit.Case, async: true

  alias GatewayKit.Config.{Route, Transform}
  alias GatewayKit.Context
  alias GatewayKit.Context.Request
  alias GatewayKit.Transform.Headers

  @ctx Context.new(%Request{}, %Route{id: 1, path: "/api"})

  describe "GatewayKit.Transform.Headers.transform/3" do
    test "removes, adds, and resolves dynamic values" do
      transform = %Transform{
        add_headers: [{"x-gateway", {:literal, "gatewaykit"}}, {"x-route", {:var, "$route_path"}}],
        remove_headers: ["x-debug"]
      }

      headers = [{"x-debug", "1"}, {"accept", "*/*"}]

      assert Headers.transform(headers, transform, @ctx) ==
               [{"accept", "*/*"}, {"x-gateway", "gatewaykit"}, {"x-route", "/api"}]
    end

    test "adding a header replaces an existing one instead of duplicating it" do
      transform = %Transform{add_headers: [{"x-served-by", {:literal, "gatewaykit"}}]}

      assert Headers.transform([{"x-served-by", "upstream"}], transform, @ctx) == [{"x-served-by", "gatewaykit"}]
    end
  end
end
