defmodule GatewayKit.Stage.TransformTest do
  use GatewayKit.GatewayCase, async: true

  alias GatewayKit.Config.{Route, Transform}
  alias GatewayKit.Context
  alias GatewayKit.Context.{Request, Response}
  alias GatewayKit.Stage

  @moduletag :capture_log

  describe "GatewayKit.Stage.ResponseTransform.call/2" do
    setup do
      transform = %Transform{body: {:envelope, %{"data" => {:var, "$body"}}}}
      %{ctx: Context.new(%Request{}, %Route{id: 1, path: "/api", response_transform: transform})}
    end

    test "embeds a non-JSON upstream body as a string and recomputes the headers", %{ctx: ctx} do
      upstream = %Response{
        status: 200,
        headers: [{"content-type", "text/plain"}, {"content-length", "5"}],
        body: "hello"
      }

      result = Stage.ResponseTransform.call(ctx, &Context.respond(&1, upstream))

      assert result.response.body == ~s({"data":"hello"})
      assert result.response.headers == [{"content-length", "16"}, {"content-type", "application/json"}]
    end

    test "leaves gateway-generated responses and unreadable bodies alone", %{ctx: ctx} do
      halted = Stage.ResponseTransform.call(ctx, &Context.halt(&1, 502, %{error: "bad_gateway"}))
      assert halted.response.body == ~s({"error":"bad_gateway"})

      encoded = %Response{status: 200, headers: [{"content-encoding", "gzip"}], body: <<31, 139, 8>>}
      passthrough = Stage.ResponseTransform.call(ctx, &Context.respond(&1, encoded))
      assert passthrough.response == encoded
    end
  end

  describe "transforms end to end" do
    setup do
      upstream = start_supervised!(MockUpstream)
      port = MockUpstream.port(upstream)
      gateway = start_gateway_from_yaml("test/support/configs/transform.yaml", %{UPSTREAM_PORT: port})
      %{gateway: gateway, upstream: upstream}
    end

    test "rewrites request headers and restructures the JSON body", %{gateway: gateway, upstream: upstream} do
      body = Jason.encode!(%{"userId" => "u1", "userName" => "Ann", "extra" => "dropped"})
      headers = [{"content-type", "application/json"}, {"x-debug", "1"}, {"x-internal", "1"}, {"x-keep", "1"}]

      {:ok, response} = request(gateway, :post, "/api/legacy/v1/data", body: body, headers: headers)

      assert response.status == 200
      [seen] = MockUpstream.requests(upstream)
      assert seen.path == "/v1/data"
      assert seen.headers["x-gateway"] == "gatewaykit"
      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(seen.headers["x-request-start"])
      assert seen.headers["x-keep"] == "1"
      refute Map.has_key?(seen.headers, "x-debug") or Map.has_key?(seen.headers, "x-internal")

      assert %{"user" => %{"id" => "u1", "name" => "Ann"}, "meta" => %{"source" => "gateway", "timestamp" => ts}} =
               Jason.decode!(seen.body)

      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(ts)
      assert seen.headers["content-length"] == Integer.to_string(byte_size(seen.body))
    end

    test "forwards a non-JSON request body untouched", %{gateway: gateway, upstream: upstream} do
      {:ok, _response} = request(gateway, :post, "/api/legacy/raw", body: "not json")

      assert [%{body: "not json"}] = MockUpstream.requests(upstream)
    end

    test "wraps the upstream response in the envelope and rewrites its headers", %{gateway: gateway} do
      {:ok, response} = request(gateway, :get, "/api/legacy/canned")

      assert response.status == 200

      assert %{"data" => %{"message" => "canned", "source" => "upstream"}, "gateway_metadata" => metadata} =
               json(response)

      assert %{"route" => "/api/legacy", "served_at" => served_at} = metadata
      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(served_at)

      assert header(response, "x-served-by") == "gatewaykit"
      assert header(response, "content-type") == "application/json"
      assert header(response, "content-length") == Integer.to_string(byte_size(response.body))
      refute header(response, "server") || header(response, "x-powered-by")
    end

    test "gateway errors keep the uniform error shape", %{gateway: gateway, upstream: upstream} do
      :ok = MockUpstream.stop(upstream)

      {:ok, response} = request(gateway, :get, "/api/legacy/canned")

      assert {502, %{"error" => "bad_gateway"}} = {response.status, json(response)}
    end
  end
end
