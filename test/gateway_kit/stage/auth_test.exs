defmodule GatewayKit.Stage.AuthTest do
  use GatewayKit.GatewayCase, async: true

  alias GatewayKit.Config.{Auth, Route}
  alias GatewayKit.Context
  alias GatewayKit.Context.Request
  alias GatewayKit.Stage

  @route %Route{id: 1, path: "/api", auth: %Auth{type: :api_key, header: "x-api-key", keys: ["k1", "k2"]}}
  @unauthorized ~s({"error":"unauthorized"})

  defp run(headers) do
    ctx = Context.new(%Request{headers: headers}, @route)
    Stage.Auth.call(ctx, &Context.assign(&1, :reached_next, true))
  end

  describe "GatewayKit.Stage.Auth.enabled?/1" do
    test "only for routes with an auth block" do
      assert Stage.Auth.enabled?(@route)
      refute Stage.Auth.enabled?(%Route{@route | auth: nil})
    end
  end

  describe "GatewayKit.Stage.Auth.call/2" do
    test "passes a request carrying any configured key through" do
      assert %Context{assigns: %{reached_next: true}, halted?: false} = run([{"x-api-key", "k1"}])
      assert %Context{assigns: %{reached_next: true}} = run([{"other", "x"}, {"x-api-key", "k2"}])
    end

    test "halts with an identical 401 for a missing and for a wrong key" do
      missing = run([])
      wrong = run([{"x-api-key", "k1 "}])

      assert %Context{halted?: true, response: %{status: 401, body: @unauthorized}} = missing
      assert %Context{halted?: true, response: %{status: 401, body: @unauthorized}} = wrong
      assert missing.response == wrong.response
      refute Map.has_key?(missing.assigns, :reached_next)
    end
  end

  describe "api_key auth end to end" do
    setup do
      upstream = start_supervised!(MockUpstream)
      gateway = start_gateway_from_yaml("test/support/configs/auth.yaml", %{UPSTREAM_PORT: MockUpstream.port(upstream)})
      %{gateway: gateway}
    end

    test "rejects requests without a valid key before they reach the upstream", %{gateway: gateway} do
      {:ok, missing} = request(gateway, :get, "/api/secure")
      {:ok, wrong} = request(gateway, :get, "/api/secure", headers: [{"X-API-Key", "nope"}])

      assert {401, %{"error" => "unauthorized"}} = {missing.status, json(missing)}
      assert {401, %{"error" => "unauthorized"}} = {wrong.status, json(wrong)}
    end

    test "proxies requests with a valid key, header name case-insensitively", %{gateway: gateway} do
      {:ok, response} = request(gateway, :get, "/api/secure/thing", headers: [{"X-Api-Key", "k2"}])

      assert response.status == 200
      assert %{"path" => "/api/secure/thing"} = json(response)
    end
  end
end
