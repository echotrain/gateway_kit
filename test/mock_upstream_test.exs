defmodule GatewayKit.MockUpstreamTest do
  use GatewayKit.GatewayCase, async: true

  setup do
    upstream = start_supervised!(MockUpstream)
    %{upstream: upstream, target: %{url: MockUpstream.url(upstream)}}
  end

  describe "GatewayKit.MockUpstream.port/1" do
    test "binds a distinct ephemeral port per instance", %{upstream: upstream} do
      other = start_supervised!(MockUpstream)

      assert MockUpstream.port(upstream) > 0
      assert MockUpstream.port(other) > 0
      assert MockUpstream.port(upstream) != MockUpstream.port(other)
    end
  end

  describe "GatewayKit.MockUpstream.url/1" do
    test "is the loopback address on the bound port", %{upstream: upstream} do
      assert MockUpstream.url(upstream) == "http://127.0.0.1:#{MockUpstream.port(upstream)}"
    end
  end

  describe "GatewayKit.MockUpstream.call/2" do
    test "echoes method, path, query, headers and body for unmatched paths", %{target: target} do
      {:ok, response} =
        request(target, :post, "/echo/deep/path", query: "a=1&b=2", headers: [{"x-test", "yes"}], body: "hello")

      assert response.status == 200

      assert %{
               "method" => "POST",
               "path" => "/echo/deep/path",
               "query" => "a=1&b=2",
               "headers" => %{"x-test" => "yes"},
               "body" => "hello"
             } = json(response)
    end

    test "tags every response with JSON content type and its own port", %{target: target, upstream: upstream} do
      {:ok, response} = request(target, :get, "/anything")

      assert header(response, "content-type") == "application/json"
      assert header(response, "x-upstream-port") == Integer.to_string(MockUpstream.port(upstream))
    end

    test "serves the canned response with headers a gateway should strip", %{target: target} do
      {:ok, response} = request(target, :get, "/canned")

      assert response.status == 200
      assert json(response) == %{"message" => "canned", "source" => "upstream"}
      assert header(response, "server") == "mock-upstream"
      assert header(response, "x-powered-by") == "mock"
    end

    test "responds with the requested status code", %{target: target} do
      {:ok, response} = request(target, :get, "/status/503")

      assert response.status == 503
      assert json(response) == %{"status" => 503}
    end

    test "matches endpoints on the trailing path segments", %{target: target} do
      {:ok, response} = request(target, :get, "/api/orders/status/418")

      assert response.status == 418
      assert json(response) == %{"status" => 418}
    end

    test "echoes when a status or slow segment is not an integer", %{target: target} do
      {:ok, response} = request(target, :get, "/api/orders/status/pending")

      assert response.status == 200
      assert json(response)["path"] == "/api/orders/status/pending"
    end

    test "delays the slow endpoint by the requested milliseconds", %{target: target} do
      started_at = System.monotonic_time(:millisecond)
      {:ok, response} = request(target, :get, "/slow/50")

      assert response.status == 200
      assert json(response) == %{"slept_ms" => 50}
      assert System.monotonic_time(:millisecond) - started_at >= 50
    end

    test "fails the flaky endpoint twice by default, then succeeds", %{target: target} do
      assert {:ok, %{status: 503}} = request(target, :get, "/flaky")
      assert {:ok, %{status: 503}} = request(target, :get, "/flaky")
      assert {:ok, %{status: 200} = response} = request(target, :get, "/flaky")
      assert json(response) == %{"attempt" => 3}
    end

    test "honours the flaky_failures option" do
      upstream = start_supervised!({MockUpstream, flaky_failures: 1})
      target = %{url: MockUpstream.url(upstream)}

      assert {:ok, %{status: 503}} = request(target, :get, "/flaky")
      assert {:ok, %{status: 200}} = request(target, :get, "/flaky")
    end
  end

  describe "GatewayKit.MockUpstream.reset_flaky/1" do
    test "restarts the failure sequence", %{target: target, upstream: upstream} do
      for _ <- 1..3, do: {:ok, _response} = request(target, :get, "/flaky")
      assert {:ok, %{status: 200}} = request(target, :get, "/flaky")

      assert MockUpstream.reset_flaky(upstream) == :ok

      assert {:ok, %{status: 503} = response} = request(target, :get, "/flaky")
      assert json(response)["attempt"] == 1
    end
  end

  describe "GatewayKit.MockUpstream.set_healthy/2" do
    test "flips /healthz between 200 and 503", %{target: target, upstream: upstream} do
      assert {:ok, %{status: 200} = healthy} = request(target, :get, "/healthz")
      assert json(healthy) == %{"status" => "ok"}

      assert MockUpstream.set_healthy(upstream, false) == :ok
      assert {:ok, %{status: 503} = unhealthy} = request(target, :get, "/healthz")
      assert json(unhealthy) == %{"status" => "unhealthy"}

      assert MockUpstream.set_healthy(upstream, true) == :ok
      assert {:ok, %{status: 200}} = request(target, :get, "/healthz")
    end
  end

  describe "GatewayKit.MockUpstream.requests/1" do
    test "records every request in order", %{target: target, upstream: upstream} do
      assert MockUpstream.requests(upstream) == []

      {:ok, _first} = request(target, :get, "/first", query: "q=1")
      {:ok, _second} = request(target, :put, "/second", headers: [{"x-seq", "2"}], body: "payload")

      assert [
               %{method: "GET", path: "/first", query: "q=1", body: ""},
               %{method: "PUT", path: "/second", query: "", body: "payload", headers: %{"x-seq" => "2"}}
             ] = MockUpstream.requests(upstream)
    end
  end

  describe "GatewayKit.MockUpstream.stop/1" do
    test "refuses connections afterwards", %{target: target, upstream: upstream} do
      assert MockUpstream.stop(upstream) == :ok

      assert {:error, %Finch.TransportError{reason: :econnrefused}} = request(target, :get, "/echo")
    end
  end
end
