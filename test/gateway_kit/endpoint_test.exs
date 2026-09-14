defmodule GatewayKit.EndpointTest do
  use GatewayKit.GatewayCase, async: true

  alias GatewayKit.Config.Loader

  @moduletag :capture_log

  setup do
    upstream = start_supervised!(MockUpstream)
    %{upstream: upstream, url: MockUpstream.url(upstream)}
  end

  describe "GET /health" do
    test "always answers 200 with the mandated shape, even with no routes" do
      gateway = start_gateway(config([]))

      {:ok, response} = request(gateway, :get, "/health")

      assert response.status == 200
      assert header(response, "content-type") =~ "application/json"
      assert %{"status" => "healthy", "uptime_seconds" => uptime} = json(response)
      assert is_integer(uptime) and uptime >= 0
    end

    test "takes precedence over a configured /health route", %{url: url} do
      gateway = start_gateway(config([route("/health", url)]))

      {:ok, response} = request(gateway, :get, "/health")

      assert %{"status" => "healthy"} = json(response)
    end
  end

  describe "routing errors" do
    test "an unmatched path is a JSON 404", %{url: url} do
      gateway = start_gateway(config([route("/api/users", url)]))

      {:ok, response} = request(gateway, :get, "/api/nope")

      assert response.status == 404
      assert json(response) == %{"error" => "not_found"}
    end

    test "a matched path with a disallowed method is 405 with Allow", %{url: url} do
      gateway = start_gateway(config([route("/api/users", url, %{"methods" => ["GET", "POST"]})]))

      {:ok, response} = request(gateway, :delete, "/api/users")

      assert response.status == 405
      assert header(response, "allow") == "GET, POST"
      assert json(response) == %{"error" => "method_not_allowed"}
    end
  end

  describe "proxying" do
    test "forwards method, path, query, and body, and returns the upstream response", %{upstream: upstream, url: url} do
      gateway = start_gateway(config([route("/api/echo", url)]))

      {:ok, response} = request(gateway, :post, "/api/echo/items", query: "page=2&sort=asc", body: "hello")

      assert response.status == 200
      assert header(response, "content-type") == "application/json"
      assert header(response, "x-upstream-port") == to_string(MockUpstream.port(upstream))

      assert %{"method" => "POST", "path" => "/api/echo/items", "query" => "page=2&sort=asc", "body" => "hello"} =
               json(response)
    end

    test "rewrites host and appends the forwarding headers", %{upstream: upstream, url: url} do
      gateway = start_gateway(config([route("/api/echo", url)]))

      {:ok, response} = request(gateway, :get, "/api/echo", headers: [{"x-forwarded-for", "10.0.0.1"}])

      assert %{"headers" => headers} = json(response)
      assert headers["host"] == "127.0.0.1:#{MockUpstream.port(upstream)}"
      assert headers["x-forwarded-for"] == "10.0.0.1, 127.0.0.1"
      assert headers["x-forwarded-proto"] == "http"
      assert headers["x-forwarded-host"] == "127.0.0.1:#{gateway.port}"
    end

    test "strips hop-by-hop headers, including those named in Connection", %{url: url} do
      gateway = start_gateway(config([route("/api/echo", url)]))

      hop_by_hop = [
        {"connection", "close, x-hop"},
        {"x-hop", "1"},
        {"te", "trailers"},
        {"keep-alive", "timeout=5"},
        {"proxy-authorization", "secret"},
        {"x-end-to-end", "kept"}
      ]

      {:ok, response} = request(gateway, :get, "/api/echo", headers: hop_by_hop)

      assert %{"headers" => headers} = json(response)
      assert headers["x-end-to-end"] == "kept"
      refute Enum.any?(~w(connection x-hop te keep-alive proxy-authorization), &Map.has_key?(headers, &1))
    end

    test "strip_prefix rewrites the path and forwards / on an exact match", %{url: url} do
      gateway = start_gateway(config([route("/api/svc", url, %{"strip_prefix" => true})]))

      {:ok, nested} = request(gateway, :get, "/api/svc/v1/data", query: "q=1")
      {:ok, exact} = request(gateway, :get, "/api/svc")

      assert %{"path" => "/v1/data", "query" => "q=1"} = json(nested)
      assert %{"path" => "/"} = json(exact)
    end

    test "percent-encoding survives strip_prefix", %{url: url} do
      gateway = start_gateway(config([route("/api/svc", url, %{"strip_prefix" => true})]))

      {:ok, response} = request(gateway, :get, "/api/svc/a%20b/c%2Fd")

      assert %{"path" => "/a%20b/c%2Fd"} = json(response)
    end

    test "joins the request path onto an upstream base path", %{url: url} do
      gateway = start_gateway(config([route("/api/echo", url <> "/base/")]))

      {:ok, response} = request(gateway, :get, "/api/echo/x")

      assert %{"path" => "/base/api/echo/x"} = json(response)
    end
  end

  describe "upstream failures" do
    test "a refused connection is a 502", %{upstream: upstream, url: url} do
      gateway = start_gateway(config([route("/api/echo", url)]))
      :ok = MockUpstream.stop(upstream)

      {:ok, response} = request(gateway, :get, "/api/echo")

      assert response.status == 502
      assert json(response) == %{"error" => "bad_gateway"}
    end

    test "a slow upstream is a 504 after the route timeout", %{url: url} do
      gateway = start_gateway(config([route("/api/echo", url, %{"upstream" => %{"url" => url, "timeout" => "100ms"}})]))

      {elapsed_us, {:ok, response}} = :timer.tc(fn -> request(gateway, :get, "/api/echo/slow/2000") end)

      assert response.status == 504
      assert json(response) == %{"error" => "gateway_timeout"}
      assert elapsed_us < 1_500_000
    end
  end

  describe "config fixtures" do
    @fixtures Path.wildcard("examples/{minimal,alternate}.yaml") ++ Path.wildcard("test/support/configs/*.yaml")

    test "the spec config and every fixture boot and serve /health", %{upstream: upstream} do
      port = MockUpstream.port(upstream)

      for path <- ["gateway.yaml" | @fixtures] do
        gateway = start_gateway_from_yaml(path, %{UPSTREAM_PORT: port, UPSTREAM_PORT_2: port})
        {:ok, response} = request(gateway, :get, "/health")
        assert %{"status" => "healthy"} = json(response), "#{path} did not serve /health"
      end
    end

    test "the alternate config's routes and catch-all are live" do
      gateway = start_gateway_from_yaml("examples/alternate.yaml")

      {:ok, search} = request(gateway, :post, "/v2/search")
      {:ok, catch_all} = request(gateway, :post, "/anything/else")

      assert {405, "GET"} = {search.status, header(search, "allow")}
      assert {405, "GET"} = {catch_all.status, header(catch_all, "allow")}
    end

    test "the invalid example yields a report naming every error" do
      assert {:error, {:invalid, errors}} = Loader.load("examples/invalid.yaml")

      paths = Enum.map(errors, & &1.path)
      assert "gateway.port" in paths
      assert "routes[1].rate_limit.window" in paths
      assert "routes[2].upstream" in paths
      assert length(errors) >= 4
    end
  end
end
