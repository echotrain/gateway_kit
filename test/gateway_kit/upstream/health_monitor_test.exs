defmodule GatewayKit.Upstream.HealthMonitorTest do
  use GatewayKit.GatewayCase, async: true

  alias GatewayKit.Config.{HealthCheck, Route, Target, Upstream}
  alias GatewayKit.Server
  alias GatewayKit.Upstream.{Balancer, Health, HealthMonitor}

  @moduletag :capture_log

  # Mirrors the validator's normalization: a target URI always carries a string path.
  defp target(upstream, weight) do
    url = MockUpstream.url(upstream)
    %Target{url: url, uri: %URI{URI.parse(url) | path: ""}, weight: weight}
  end

  describe "GatewayKit.Upstream.HealthMonitor.check_now/1" do
    setup do
      primary = start_supervised!(MockUpstream)
      backup = start_supervised!(MockUpstream)
      targets = [target(primary, 3), target(backup, 1)]
      ring = targets |> Enum.flat_map(&List.duplicate(&1, &1.weight)) |> List.to_tuple()

      route = %Route{
        id: System.unique_integer([:positive]),
        path: "/api/lb",
        segments: ["api", "lb"],
        methods: ["GET"],
        upstream: %Upstream{targets: targets, balance: :weighted_round_robin, timeout_ms: 1_000, ring: ring},
        health_check: %HealthCheck{path: "/healthz", interval_ms: 3_600_000, unhealthy_threshold: 2}
      }

      monitor = start_supervised!({HealthMonitor, route})
      %{route: route, monitor: monitor, primary: primary, backup: backup, targets: targets}
    end

    test "marks a target unhealthy after consecutive failures and healthy after one success", context do
      %{route: route, monitor: monitor, backup: backup, targets: [primary_target, backup_target]} = context

      HealthMonitor.check_now(monitor)
      assert Health.healthy?(route.id, backup_target)

      MockUpstream.set_healthy(backup, false)
      HealthMonitor.check_now(monitor)
      assert Health.healthy?(route.id, backup_target)

      HealthMonitor.check_now(monitor)
      refute Health.healthy?(route.id, backup_target)
      assert Health.healthy?(route.id, primary_target)

      MockUpstream.set_healthy(backup, true)
      HealthMonitor.check_now(monitor)
      assert Health.healthy?(route.id, backup_target)
    end

    test "a success resets the consecutive-failure count", context do
      %{route: route, monitor: monitor, backup: backup, targets: [_primary, backup_target]} = context

      MockUpstream.set_healthy(backup, false)
      HealthMonitor.check_now(monitor)
      MockUpstream.set_healthy(backup, true)
      HealthMonitor.check_now(monitor)
      MockUpstream.set_healthy(backup, false)
      HealthMonitor.check_now(monitor)

      assert Health.healthy?(route.id, backup_target)
    end

    test "an unreachable target counts as failing", context do
      %{route: route, monitor: monitor, backup: backup, targets: [_primary, backup_target]} = context

      :ok = MockUpstream.stop(backup)
      HealthMonitor.check_now(monitor)
      HealthMonitor.check_now(monitor)

      refute Health.healthy?(route.id, backup_target)
    end

    test "the balancer skips unhealthy targets and fails closed when none are left", context do
      %{route: route, monitor: monitor, primary: primary, backup: backup, targets: [primary_target, _backup]} = context

      MockUpstream.set_healthy(backup, false)
      for _ <- 1..2, do: HealthMonitor.check_now(monitor)

      assert Enum.all?(1..8, fn _ -> Balancer.select(route) == {:ok, primary_target} end)

      MockUpstream.set_healthy(primary, false)
      for _ <- 1..2, do: HealthMonitor.check_now(monitor)

      assert Balancer.select(route) == {:error, :no_healthy_upstream}
    end
  end

  describe "health checks through a gateway" do
    setup do
      primary = start_supervised!(MockUpstream)
      backup = start_supervised!(MockUpstream)

      upstream = %{
        "targets" => [%{"url" => MockUpstream.url(primary), "weight" => 3}, %{"url" => MockUpstream.url(backup)}],
        "balance" => "weighted_round_robin"
      }

      health_check = %{"path" => "/healthz", "interval" => "1h", "unhealthy_threshold" => 1}
      route = route("/api/lb", MockUpstream.url(primary), %{"upstream" => upstream, "health_check" => health_check})
      gateway = start_gateway(config([route, route("/api/plain", MockUpstream.url(primary))]))

      %{gateway: gateway, primary: primary, backup: backup}
    end

    test "the instance runs one monitor per health-checked route, and routes around dead targets", context do
      %{gateway: gateway, primary: primary, backup: backup} = context

      assert [monitor] = Server.health_monitors(gateway.pid)

      :ok = MockUpstream.stop(backup)
      HealthMonitor.check_now(monitor)

      ports = Enum.map(1..8, fn _ -> gateway |> request(:get, "/api/lb") |> elem(1) |> header("x-upstream-port") end)
      assert Enum.uniq(ports) == [Integer.to_string(MockUpstream.port(primary))]

      :ok = MockUpstream.stop(primary)
      HealthMonitor.check_now(monitor)

      {:ok, response} = request(gateway, :get, "/api/lb")
      assert {503, %{"error" => "no_healthy_upstream"}} = {response.status, json(response)}
    end
  end
end
