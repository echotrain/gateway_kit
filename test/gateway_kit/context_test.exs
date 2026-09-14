defmodule GatewayKit.ContextTest do
  use ExUnit.Case, async: true

  alias GatewayKit.Config.Route
  alias GatewayKit.Context
  alias GatewayKit.Context.{Request, Response}

  setup do
    %{ctx: Context.new(%Request{method: "POST", path: "/api"}, %Route{id: 1, path: "/api"})}
  end

  describe "GatewayKit.Context.new/2" do
    test "starts un-halted with a request timestamp", %{ctx: ctx} do
      assert %Context{halted?: false, response: nil, error: nil, assigns: %{}} = ctx
      assert %DateTime{} = ctx.started_at
      assert ctx.request.method == "POST"
      assert ctx.route.path == "/api"
    end
  end

  describe "GatewayKit.Context.halt/4" do
    test "sets a JSON gateway response and marks the context halted", %{ctx: ctx} do
      halted = Context.halt(ctx, 429, %{error: "rate_limit_exceeded", retry_after: 3}, [{"retry-after", "3"}])

      assert %Context{halted?: true, response: %Response{status: 429, body: body, headers: headers}} = halted
      assert Jason.decode!(body) == %{"error" => "rate_limit_exceeded", "retry_after" => 3}
      assert headers == [{"content-type", "application/json"}, {"retry-after", "3"}]
    end
  end

  describe "GatewayKit.Context.respond/2" do
    test "records an upstream response without halting", %{ctx: ctx} do
      response = %Response{status: 201, headers: [{"x-a", "1"}], body: "ok"}
      assert %Context{halted?: false, response: ^response} = Context.respond(ctx, response)
    end
  end

  describe "GatewayKit.Context.put_error/2 and assign/3" do
    test "store the failure reason and stage scratch data", %{ctx: ctx} do
      ctx = ctx |> Context.put_error(:econnrefused) |> Context.assign(:attempt, 2)
      assert %Context{error: :econnrefused, assigns: %{attempt: 2}} = ctx
    end
  end
end
